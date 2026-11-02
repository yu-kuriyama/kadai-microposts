import AVFoundation
import CommonCrypto
import Foundation

public enum HLSError: LocalizedError {
    case invalidPlaylist
    case http(Int, String)
    case drm
    case unsupported(String)
    case noSegments
    case noMedia
    case decrypt
    case mux(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPlaylist: return "動画のプレイリストを読み取れませんでした。"
        case .http(let code, let what):
            switch code {
            case 401, 403: return "サイトにアクセスを拒否されました（HTTP \(code)・\(what)）。ページを開き直して、動画を再生してからもう一度お試しください。"
            case 404, 410: return "動画データが見つかりません（HTTP \(code)・\(what)）。ページを開き直してからもう一度お試しください。"
            default: return "サーバーエラーです（HTTP \(code)・\(what)）。"
            }
        case .drm: return "この動画はDRM（コピー防止）で保護されているため保存できません。"
        case .unsupported(let s): return "対応していない形式です（\(s)）。"
        case .noSegments: return "動画データが入っていないプレイリストでした。"
        case .noMedia: return "映像も音声も見つかりませんでした。"
        case .decrypt: return "暗号化された動画の復号に失敗しました。"
        case .mux(let s): return "mp4 の作成に失敗しました: \(s)"
        }
    }
}

/// HLS（m3u8）をダウンロードして1つの mp4 にする
public final class HLSDownloader {
    public let url: URL
    public let headers: [String: String]
    public let workDir: URL
    public var maxConcurrent = 6
    public var onProgress: ((Double) -> Void)?
    /// 進行状況のログ（デバッグ用）
    public var onLog: ((String) -> Void)?
    private func note(_ s: String) { log.append(s); onLog?(s) }
    /// 選んだ画質などの説明（デバッグ用）
    public private(set) var log: [String] = []

    private let session: URLSession
    private var keyCache: [URL: Data] = [:]
    private let keyLock = NSLock()

    public init(url: URL, headers: [String: String], workDir: URL) {
        self.url = url
        self.headers = headers
        self.workDir = workDir
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    public func download(to output: URL) async throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 1. プレイリストを読んで、一番高画質のものを選ぶ
        var videoSegments: [M3U8Segment] = []
        var audioSegments: [M3U8Segment] = []
        switch try await playlist(url) {
        case .media(let segs, _):
            videoSegments = segs
        case .master(let variants, let renditions):
            guard let best = Self.chooseVariant(variants) else { throw HLSError.invalidPlaylist }
            note("variant: \(best.resolution ?? "?") \(best.bandwidth)bps \(best.codecs ?? "")")
            guard case .media(let segs, _) = try await playlist(best.uri) else { throw HLSError.invalidPlaylist }
            videoSegments = segs
            if let group = best.audioGroup {
                let candidates = renditions.filter { $0.type == "AUDIO" && $0.groupID == group && $0.uri != nil }
                if let audio = candidates.first(where: { $0.isDefault }) ?? candidates.first, let auri = audio.uri {
                    if case .media(let asegs, _) = try await playlist(auri) { audioSegments = asegs }
                    note("separate audio: \(auri.lastPathComponent)")
                }
            }
        }
        guard !videoSegments.isEmpty else { throw HLSError.noSegments }
        for s in videoSegments + audioSegments {
            if let k = s.key, k.method != "AES-128" { throw HLSError.drm }
        }

        note("segments: video \(videoSegments.count), audio \(audioSegments.count)")
        // 2. セグメントをまとめてダウンロード
        let total = videoSegments.count + audioSegments.count
        var done = 0
        let report: () -> Void = { [weak self] in
            done += 1
            self?.onProgress?(Double(done) / Double(total) * 0.92)
        }
        let vDir = workDir.appendingPathComponent("v")
        let aDir = workDir.appendingPathComponent("a")
        try await fetchSegments(videoSegments, into: vDir, progress: report)
        if !audioSegments.isEmpty { try await fetchSegments(audioSegments, into: aDir, progress: report) }

        note("downloaded")
        // 3. つなげて mp4 にする
        let videoTrack = try await buildTrack(videoSegments, dir: vDir, name: "video")
        if audioSegments.isEmpty {
            try await finalize([videoTrack], to: output)
        } else {
            let audioTrack = try await buildTrack(audioSegments, dir: aDir, name: "audio")
            try await finalize([videoTrack, audioTrack], to: output)
        }
        onProgress?(1)
    }

    static func chooseVariant(_ variants: [M3U8Variant]) -> M3U8Variant? {
        // HEVC などより H.264 を優先し、その中で一番高いビットレート
        let avc = variants.filter { v in
            guard let c = v.codecs?.lowercased() else { return true }
            return !["hvc1", "hev1", "av01", "vp09", "dvh1", "dvhe"].contains { c.contains($0) }
        }
        return (avc.isEmpty ? variants : avc).max { $0.bandwidth < $1.bandwidth }
    }

    // MARK: - 通信

    private func request(_ url: URL, range: ByteRange? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let range { r.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range") }
        return r
    }

    private func fetch(_ url: URL, range: ByteRange? = nil, what: String) async throws -> Data {
        var lastError: Error = HLSError.noSegments
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request(url, range: range))
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    if [401, 403, 404, 410].contains(http.statusCode) { throw HLSError.http(http.statusCode, what) }
                    lastError = HLSError.http(http.statusCode, what)
                } else if let range, data.count > range.length {
                    // サーバーが Range を無視した場合
                    let start = data.startIndex + range.offset
                    guard start + range.length <= data.endIndex else { return data }
                    return data.subdata(in: start..<(start + range.length))
                } else {
                    return data
                }
            } catch let e as HLSError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
                lastError = error
            }
            try await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
        }
        throw lastError
    }

    private func playlist(_ url: URL) async throws -> M3U8Playlist {
        let data = try await fetch(url, what: "プレイリスト")
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw HLSError.invalidPlaylist
        }
        return try M3U8Parser.parse(text, baseURL: url)
    }

    private func key(_ k: M3U8Key) async throws -> Data {
        guard let uri = k.uri else { throw HLSError.decrypt }
        keyLock.lock()
        let cached = keyCache[uri]
        keyLock.unlock()
        if let cached { return cached }
        let data = try await fetch(uri, what: "復号キー")
        guard data.count == 16 else { throw HLSError.decrypt }
        keyLock.lock()
        keyCache[uri] = data
        keyLock.unlock()
        return data
    }

    private func decrypt(_ data: Data, key k: M3U8Key?, sequence: Int) async throws -> Data {
        guard let k, k.method == "AES-128" else { return data }
        let keyData = try await key(k)
        var iv = k.iv ?? Data(count: 16)
        if k.iv == nil {
            var seq = UInt64(sequence).bigEndian
            iv.replaceSubrange(8..<16, with: Data(bytes: &seq, count: 8))
        }
        return try Self.aes128cbc(data, key: keyData, iv: iv)
    }

    static func aes128cbc(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, kCCKeySizeAES128, v.baseAddress,
                                d.baseAddress, data.count, o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw HLSError.decrypt }
        return out.prefix(moved)
    }

    private func fetchSegments(_ segments: [M3U8Segment], into dir: URL, progress: @escaping () -> Void) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 初期化セグメント（fMP4 の場合）
        var maps: [M3U8Map] = []
        for s in segments { if let m = s.map, !maps.contains(m) { maps.append(m) } }
        for (i, m) in maps.enumerated() {
            let file = dir.appendingPathComponent("init\(i)")
            if FileManager.default.fileExists(atPath: file.path) { continue }
            var data = try await fetch(m.uri, range: m.byteRange, what: "初期化データ")
            if m.key != nil { data = try await decrypt(data, key: m.key, sequence: 0) }
            try data.write(to: file, options: .atomic)
        }

        let progressLock = NSLock()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func addTask() {
                let i = next
                next += 1
                let seg = segments[i]
                let file = dir.appendingPathComponent(String(format: "%06d", i))
                group.addTask {
                    if !FileManager.default.fileExists(atPath: file.path) {
                        let raw = try await self.fetch(seg.uri, range: seg.byteRange, what: "動画データ \(i + 1)/\(segments.count)")
                        let data = try await self.decrypt(raw, key: seg.key, sequence: seg.sequence)
                        try data.write(to: file, options: .atomic)
                    }
                    progressLock.lock()
                    progress()
                    progressLock.unlock()
                }
            }
            for _ in 0..<min(maxConcurrent, segments.count) { addTask() }
            while try await group.next() != nil {
                if next < segments.count { addTask() }
            }
        }
    }

    // MARK: - 組み立て

    private enum Container { case ts, fmp4, adts }

    private static func detect(_ data: Data, hasMap: Bool) -> Container {
        let b = [UInt8](data.prefix(12))
        if hasMap { return .fmp4 }
        if b.first == 0x47 { return .ts }
        if b.count >= 8 {
            let type = String(bytes: b[4..<8], encoding: .ascii) ?? ""
            if ["ftyp", "styp", "moof", "sidx", "moov"].contains(type) { return .fmp4 }
        }
        if b.count >= 3, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return .adts }
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xF6) == 0xF0 { return .adts }
        // 先頭にゴミがある TS
        if let i = b.firstIndex(of: 0x47), data.count > i + 188, data[data.startIndex + i + 188] == 0x47 { return .ts }
        return .ts
    }

    private func buildTrack(_ segments: [M3U8Segment], dir: URL, name: String) async throws -> URL {
        let firstFile = dir.appendingPathComponent(String(format: "%06d", 0))
        let first = try Data(contentsOf: firstFile)
        let output = workDir.appendingPathComponent("\(name).mp4")
        try? FileManager.default.removeItem(at: output)

        let container = Self.detect(first, hasMap: segments.first?.map != nil)
        note("build \(name): \(container)")
        switch container {
        case .fmp4:
            // 初期化データ + セグメントをそのままつなげる
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            var lastMap: M3U8Map?
            var maps: [M3U8Map] = []
            for s in segments { if let m = s.map, !maps.contains(m) { maps.append(m) } }
            for (i, s) in segments.enumerated() {
                if let m = s.map, m != lastMap, let idx = maps.firstIndex(of: m), lastMap == nil {
                    handle.write(try Data(contentsOf: dir.appendingPathComponent("init\(idx)")))
                    lastMap = m
                }
                handle.write(try Data(contentsOf: dir.appendingPathComponent(String(format: "%06d", i))))
            }
            return output

        case .ts:
            let demuxer = TSDemuxer()
            let writer = try MP4Writer(output: output)
            do {
                for i in 0..<segments.count {
                    try Task.checkCancellation()
                    demuxer.feed(try Data(contentsOf: dir.appendingPathComponent(String(format: "%06d", i))))
                    if i == segments.count - 1 { demuxer.flush() }
                    if !writer.isStarted {
                        if let unsupported = demuxer.unsupportedVideo, !demuxer.hasVideo { throw HLSError.unsupported(unsupported) }
                        let needVideo = demuxer.hasVideo && (demuxer.sps == nil || demuxer.pps == nil)
                        let needAudio = demuxer.hasAudio && demuxer.aacConfig == nil
                        if (needVideo || needAudio) && i < segments.count - 1 && i < 3 { continue }
                        let (v, a) = (demuxer.videoSamples, demuxer.audioSamples)
                        let base = min(v.map(\.dts).min() ?? .max, a.map(\.pts).min() ?? .max)
                        guard base != .max else { throw HLSError.noMedia }
                        try writer.start(sps: demuxer.sps, pps: demuxer.pps, aac: demuxer.aacConfig, base: base)
                        note("writer started: video=\(demuxer.sps != nil) audio=\(demuxer.aacConfig != nil) base=\(base)")
                    }
                    let (v, a) = demuxer.takeSamples()
                    note("segment \(i): video \(v.count) audio \(a.count)")
                    try writer.append(video: v, audio: a)
                    onProgress?(0.92 + 0.07 * Double(i + 1) / Double(segments.count))
                }
                note("finishing writer")
                try await writer.finish()
                note("writer finished")
            } catch {
                writer.cancel()
                throw error
            }
            return output

        case .adts:
            let demuxer = PackedAudioDemuxer()
            let writer = try MP4Writer(output: output)
            do {
                for i in 0..<segments.count {
                    try Task.checkCancellation()
                    demuxer.feed(try Data(contentsOf: dir.appendingPathComponent(String(format: "%06d", i))))
                    let samples = demuxer.takeSamples()
                    if !writer.isStarted {
                        guard let cfg = demuxer.aacConfig, let base = samples.first?.pts else { continue }
                        try writer.start(sps: nil, pps: nil, aac: cfg, base: base)
                    }
                    try writer.append(video: [], audio: samples)
                }
                try await writer.finish()
            } catch {
                writer.cancel()
                throw error
            }
            return output
        }
    }

    /// 1本ならそのまま書き出し、映像と音声が別なら合成して mp4 にする
    private func finalize(_ tracks: [URL], to output: URL) async throws {
        note("finalize \(tracks.count) track file(s)")
        try? FileManager.default.removeItem(at: output)
        let composition = AVMutableComposition()
        var duration = CMTime.zero
        for (index, url) in tracks.enumerated() {
            let asset = AVURLAsset(url: url)
            let d = try await asset.load(.duration)
            if index == 0 { duration = d }
            for type in index == 0 ? [AVMediaType.video, .audio] : [.audio] {
                for t in try await asset.loadTracks(withMediaType: type) {
                    guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    let range = try await t.load(.timeRange)
                    let end = index == 0 ? range.duration : CMTimeMinimum(range.duration, duration)
                    try track.insertTimeRange(CMTimeRange(start: range.start, duration: end), of: t, at: .zero)
                }
            }
        }
        guard !composition.tracks.isEmpty else { throw HLSError.noMedia }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw HLSError.mux("書き出しを準備できません")
        }
        session.outputURL = output
        session.outputFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        guard session.status == .completed else {
            throw HLSError.mux(session.error?.localizedDescription ?? "書き出しに失敗しました")
        }
        note("exported")
    }
}
