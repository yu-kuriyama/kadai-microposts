import AVFoundation
import Foundation
import Photos
import UIKit
import UserNotifications

struct DownloadItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, hls }
    enum Status: String, Codable { case waiting, downloading, converting, done, failed }

    var id: String = UUID().uuidString
    var url: String
    var pageURL: String?
    var title: String
    var kind: Kind
    var headers: [String: String] = [:]
    var status: Status = .waiting
    var progress: Double = 0
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var fileName: String?
    var hlsPath: String?
    var savedToPhotos = false
    var note: String?
    var error: String?
    var createdAt = Date()

    var host: String { URL(string: pageURL ?? url)?.host ?? url }
}

/// ダウンロード本体。アプリがバックグラウンドにいても続くように background URLSession を使う。
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private static let fileSessionID = "videosaver.file"
    private static let hlsSessionID = "videosaver.hls"
    private var fileSession: URLSession!
    private var hlsSession: AVAssetDownloadURLSession!
    private let storeURL: URL

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("downloads.json")
        super.init()
        UserDefaults.standard.register(defaults: ["autoSavePhotos": true])
        load()

        let fileConfig = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        fileConfig.sessionSendsLaunchEvents = true
        fileConfig.isDiscretionary = false
        fileSession = URLSession(configuration: fileConfig, delegate: self, delegateQueue: .main)

        let hlsConfig = URLSessionConfiguration.background(withIdentifier: Self.hlsSessionID)
        hlsConfig.sessionSendsLaunchEvents = true
        hlsSession = AVAssetDownloadURLSession(configuration: hlsConfig, assetDownloadDelegate: self, delegateQueue: .main)

        reconcile()
    }

    // MARK: - 追加

    /// Safari 拡張から videosaver://add?d=<base64url JSON> で呼ばれる
    func handle(url: URL) {
        guard url.scheme == "videosaver",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let d = comps.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = Self.base64URLDecode(d),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }

        var headers: [String: String] = [:]
        if let ref = payload.ref, !ref.isEmpty { headers["Referer"] = ref }
        if let ua = payload.ua, !ua.isEmpty { headers["User-Agent"] = ua }
        if let c = payload.c, !c.isEmpty { headers["Cookie"] = c }
        add(urlString: payload.u, pageURL: payload.ref, title: payload.t, headers: headers,
            kind: payload.k == "hls" ? .hls : nil)
    }

    private struct Payload: Decodable {
        let u: String
        let k: String?
        let t: String?
        let ref: String?
        let ua: String?
        let c: String?
    }

    /// 手入力（改行区切りで複数可）
    func addFromText(_ text: String) {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let urls = detector?.matches(in: text, range: range).compactMap { $0.url?.absoluteString } ?? []
        for u in urls { add(urlString: u, pageURL: nil, title: nil, headers: [:], kind: nil) }
    }

    func add(urlString: String, pageURL: String?, title: String?, headers: [String: String], kind: DownloadItem.Kind?) {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return }
        let detected: DownloadItem.Kind = url.path.lowercased().hasSuffix(".m3u8") ? .hls : .file
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        var name = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        if name.isEmpty { name = url.host ?? "video" }
        let item = DownloadItem(url: urlString, pageURL: pageURL, title: name, kind: kind ?? detected, headers: headers)
        items.insert(item, at: 0)
        save()
        requestNotificationPermission()
        start(item)
    }

    private func start(_ item: DownloadItem) {
        guard let url = URL(string: item.url) else { return }
        switch item.kind {
        case .file:
            var request = URLRequest(url: url)
            for (k, v) in item.headers { request.setValue(v, forHTTPHeaderField: k) }
            let task = fileSession.downloadTask(with: request)
            task.taskDescription = item.id
            task.resume()
        case .hls:
            var options: [String: Any] = [:]
            if !item.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = item.headers }
            let asset = AVURLAsset(url: url, options: options)
            guard let task = hlsSession.makeAssetDownloadTask(
                asset: asset,
                assetTitle: Self.safeName(item.title),
                assetArtworkData: nil,
                // できるだけ高画質を選ぶ（これ以上が無ければ一番高いもの）
                options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 50_000_000]
            ) else {
                fail(item.id, "ストリームのダウンロードを開始できませんでした。")
                return
            }
            task.taskDescription = item.id
            task.resume()
        }
        mutate(item.id, persist: true) {
            $0.status = .downloading
            $0.error = nil
            $0.note = nil
        }
    }

    // MARK: - 操作

    func retry(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        mutate(id, persist: true) {
            $0.progress = 0
            $0.receivedBytes = 0
            $0.totalBytes = 0
        }
        start(item)
    }

    func delete(_ id: String) {
        cancelTask(id)
        if let item = items.first(where: { $0.id == id }) {
            if let url = fileURL(item) { try? FileManager.default.removeItem(at: url) }
            if let pkg = hlsPackageURL(item) { try? FileManager.default.removeItem(at: pkg) }
        }
        items.removeAll { $0.id == id }
        save()
    }

    func fileURL(_ item: DownloadItem) -> URL? {
        guard let name = item.fileName else { return nil }
        let url = Self.documents.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func saveToPhotos(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), let url = fileURL(item) else { return }
        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) else {
            mutate(id, persist: true) { $0.note = "この形式は写真アプリに保存できません。「ファイル」アプリに保存されています。" }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.mutate(id, persist: true) { $0.note = "写真へのアクセスが許可されていません（設定アプリ → 動画保存 → 写真）。" }
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            }) { ok, error in
                DispatchQueue.main.async {
                    self.mutate(id, persist: true) {
                        $0.savedToPhotos = ok
                        $0.note = ok ? nil : "写真アプリへの保存に失敗しました: \(error?.localizedDescription ?? "")"
                    }
                }
            }
        }
    }

    // MARK: - 内部処理

    private func mutate(_ id: String, persist: Bool = false, _ change: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[i]
        change(&item)
        items[i] = item
        if persist { save() }
    }

    private func fail(_ id: String, _ message: String) {
        mutate(id, persist: true) {
            $0.status = .failed
            $0.error = message
        }
        if let item = items.first(where: { $0.id == id }) {
            notify(title: "ダウンロード失敗", body: item.title)
        }
    }

    private func finish(_ id: String, file: URL) {
        mutate(id, persist: true) {
            $0.status = .done
            $0.progress = 1
            $0.fileName = file.lastPathComponent
        }
        if let item = items.first(where: { $0.id == id }) {
            notify(title: "保存しました", body: item.title)
        }
        if UserDefaults.standard.bool(forKey: "autoSavePhotos") {
            saveToPhotos(id)
        }
    }

    private func cancelTask(_ id: String) {
        fileSession.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
        hlsSession.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
    }

    /// アプリが終了していた間に消えたタスクを「失敗」にする
    private func reconcile() {
        let group = DispatchGroup()
        var active = Set<String>()
        let lock = NSLock()
        let sessions: [URLSession] = [fileSession, hlsSession]
        for session in sessions {
            group.enter()
            session.getAllTasks { tasks in
                lock.lock()
                tasks.compactMap { $0.taskDescription }.forEach { active.insert($0) }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            for item in self.items where (item.status == .downloading || item.status == .waiting || item.status == .converting)
                && !active.contains(item.id) {
                self.fail(item.id, "中断されました。「再試行」を押してください。")
            }
        }
    }

    private func hlsPackageURL(_ item: DownloadItem) -> URL? {
        guard let path = item.hlsPath else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    static func safeName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        var name = title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "video" }
        if name.count > 80 { name = String(name.prefix(80)) }
        return name
    }

    private static func uniqueURL(title: String, ext: String) -> URL {
        let base = safeName(title)
        var url = documents.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = documents.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    private static func fileExtension(response: URLResponse?, url: String) -> String {
        let known = ["mp4", "m4v", "mov", "webm", "mkv", "3gp", "m4a", "mp3"]
        if let name = response?.suggestedFilename {
            let ext = (name as NSString).pathExtension.lowercased()
            if known.contains(ext) { return ext }
        }
        if let u = URL(string: url) {
            let ext = u.pathExtension.lowercased()
            if known.contains(ext) { return ext }
        }
        switch response?.mimeType?.lowercased() {
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/mpeg": return "mp3"
        default: return "mp4"
        }
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    // MARK: - HLS → mp4 変換

    private func exportHLS(_ id: String, package: URL) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        mutate(id, persist: true) { $0.status = .converting }
        let asset = AVURLAsset(url: package)
        let title = item.title
        DispatchQueue.global(qos: .userInitiated).async {
            Self.export(asset: asset, title: title,
                        presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]) { result in
                DispatchQueue.main.async {
                    try? FileManager.default.removeItem(at: package)
                    self.mutate(id) { $0.hlsPath = nil }
                    switch result {
                    case .success(let url): self.finish(id, file: url)
                    case .failure(let message): self.fail(id, "mp4への変換に失敗しました: \(message)")
                    }
                }
            }
        }
    }

    private enum ExportResult { case success(URL), failure(String) }

    private static func export(asset: AVAsset, title: String, presets: [String],
                               completion: @escaping (ExportResult) -> Void) {
        guard let preset = presets.first else {
            completion(.failure("対応していない形式です"))
            return
        }
        let rest = Array(presets.dropFirst())
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            export(asset: asset, title: title, presets: rest, completion: completion)
            return
        }
        let types = session.supportedFileTypes
        let type: AVFileType
        if types.contains(.mp4) { type = .mp4 } else if types.contains(.mov) { type = .mov } else if let first = types.first { type = first } else {
            export(asset: asset, title: title, presets: rest, completion: completion)
            return
        }
        let dest = uniqueURL(title: title, ext: type == .mov ? "mov" : "mp4")
        session.outputURL = dest
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            if session.status == .completed {
                completion(.success(dest))
            } else {
                try? FileManager.default.removeItem(at: dest)
                if rest.isEmpty {
                    completion(.failure(session.error?.localizedDescription ?? "不明なエラー"))
                } else {
                    export(asset: asset, title: title, presets: rest, completion: completion)
                }
            }
        }
    }

    // MARK: - 通知

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - URLSession のコールバック

extension DownloadManager: URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    // 通常ファイル：進み具合
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        mutate(id) {
            $0.status = .downloading
            $0.receivedBytes = totalBytesWritten
            $0.totalBytes = max(0, totalBytesExpectedToWrite)
            $0.progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        }
    }

    // 通常ファイル：完了（この関数を抜けると一時ファイルが消えるので、すぐ移動する）
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let item = items.first(where: { $0.id == id }) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail(id, "サーバーに拒否されました（HTTP \(http.statusCode)）。ページを開き直してからもう一度お試しください。")
            return
        }
        let ext = Self.fileExtension(response: downloadTask.response, url: item.url)
        let dest = Self.uniqueURL(title: item.title, ext: ext)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            finish(id, file: dest)
        } catch {
            fail(id, "ファイルを保存できませんでした: \(error.localizedDescription)")
        }
    }

    // HLS：保存場所
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.taskDescription else { return }
        mutate(id, persist: true) { $0.hlsPath = location.relativePath }
    }

    // HLS：進み具合
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + CMTimeGetSeconds($1.timeRangeValue.duration) }
        let total = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        mutate(id) {
            $0.status = .downloading
            $0.progress = total > 0 ? min(1, loaded / total) : 0
        }
    }

    // 共通：終了
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let item = items.first(where: { $0.id == id }) else { return }
        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled { return }
            if let pkg = hlsPackageURL(item) { try? FileManager.default.removeItem(at: pkg) }
            fail(id, "ダウンロードに失敗しました: \(error.localizedDescription)")
            return
        }
        if task is AVAssetDownloadTask {
            guard let pkg = hlsPackageURL(item) else {
                fail(id, "ダウンロードしたデータが見つかりません。")
                return
            }
            exportHLS(id, package: pkg)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let identifier = session.configuration.identifier,
           let handler = backgroundCompletionHandlers.removeValue(forKey: identifier) {
            handler()
        }
    }
}
