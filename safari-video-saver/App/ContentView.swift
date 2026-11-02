import AVKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @AppStorage("autoSavePhotos") private var autoSavePhotos = true
    @State private var showAdd = false
    @State private var addText = ""
    @State private var playing: PlayItem?

    var body: some View {
        NavigationStack {
            List {
                if manager.items.isEmpty {
                    Section {
                        SetupGuide()
                    } header: {
                        Text("Safariで使えるようにする")
                    }
                } else {
                    Section("ダウンロード") {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item) { url in playing = PlayItem(url: url) }
                        }
                        .onDelete { offsets in
                            offsets.map { manager.items[$0].id }.forEach(manager.delete)
                        }
                    }
                }

                Section {
                    Toggle("完了したら写真アプリに保存", isOn: $autoSavePhotos)
                } footer: {
                    Text("動画は「ファイル」アプリ →「このiPhone内」→「動画保存」にも残ります。")
                }

                if !manager.items.isEmpty {
                    Section {
                        DisclosureGroup("Safariでの使い方") { SetupGuide() }
                    }
                }
            }
            .navigationTitle("動画保存")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addText = ""
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("動画のURLを追加", isPresented: $showAdd) {
                TextField("https://…/video.mp4", text: $addText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("追加") { manager.addFromText(addText) }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("mp4 や m3u8 の直接のURLを入力してください。")
            }
            .sheet(item: $playing) { item in
                VideoPlayer(player: AVPlayer(url: item.url))
                    .ignoresSafeArea()
            }
        }
    }
}

struct PlayItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct DownloadRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let item: DownloadItem
    let play: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(item.host)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            switch item.status {
            case .waiting, .downloading:
                ProgressView(value: item.progress)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .converting:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("mp4に変換中…").font(.caption).foregroundStyle(.secondary)
                }
            case .done:
                HStack(spacing: 14) {
                    Label(item.savedToPhotos ? "写真に保存済み" : "完了",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                    if let url = manager.fileURL(item) {
                        Button { play(url) } label: { Image(systemName: "play.circle") }
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        if !item.savedToPhotos {
                            Button("写真に保存") { manager.saveToPhotos(item.id) }
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.borderless)
                if let note = item.note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            case .failed:
                Text(item.error ?? "失敗しました")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("再試行") { manager.retry(item.id) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var progressText: String {
        let percent = Int(item.progress * 100)
        if item.kind == .file, item.totalBytes > 0 {
            let f = ByteCountFormatter()
            return "\(percent)%  \(f.string(fromByteCount: item.receivedBytes)) / \(f.string(fromByteCount: item.totalBytes))"
        }
        return item.status == .waiting ? "準備中…" : "\(percent)%"
    }
}

struct SetupGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "「設定」アプリ →「アプリ」→「Safari」→「機能拡張」を開く")
            step(2, "「動画保存」をオンにして、「すべてのWebサイト」を「許可」にする")
            step(3, "Safariで動画のページを開き、アドレスバー左のボタン（ぁあ / ページメニュー）→「動画保存」を押す")
            step(4, "「保存する」を押すと、このアプリが開いてダウンロードが始まります")
            Text("動画が見つからないときは、ページで動画を一度再生してからもう一度押してください。YouTube などの一部のサイトには対応していません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(red: 1, green: 0.23, blue: 0.36)))
            Text(text).font(.subheadline)
        }
    }
}
