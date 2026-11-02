import AVFoundation
import XCTest
@testable import VideoSaverCore

struct TimeoutError: Error {}

func withTimeout(_ seconds: Double, _ body: @escaping () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            throw TimeoutError()
        }
        try await group.next()
        group.cancelAll()
    }
}

final class HLSDownloaderTests: XCTestCase {
    private var fixtures: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// ダウンロード → mp4 になっているか、最後まで再生（デコード）できるかを確認
    private func runAndVerify(_ playlist: String, expectAudio: Bool = true, file: StaticString = #filePath, line: UInt = #line) async throws {
        let dir = tempDir()
        let out = dir.appendingPathComponent("out.mp4")
        let dl = HLSDownloader(url: fixtures.appendingPathComponent(playlist), headers: ["Referer": "https://example.com/"],
                               workDir: dir.appendingPathComponent("work"))
        var lastProgress = 0.0
        dl.onProgress = { lastProgress = $0 }
        dl.onLog = { print("[\(playlist)]", $0) }
        try await withTimeout(90) { try await dl.download(to: out) }
        print("log:", dl.log)

        XCTAssertEqual(lastProgress, 1, accuracy: 0.001, file: file, line: line)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 5.3, "duration \(duration)", file: file, line: line)
        XCTAssertLessThan(duration, 6.8, "duration \(duration)", file: file, line: line)

        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1, file: file, line: line)
        XCTAssertEqual(audios.count, expectAudio ? 1 : 0, file: file, line: line)
        if let v = videos.first {
            let size = try await v.load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 160, height: 120), file: file, line: line)
        }

        // 実際にデコードしてみる
        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        if let a = audios.first {
            let o = AVAssetReaderTrackOutput(track: a, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(o)
            aOut = o
        }
        XCTAssertTrue(reader.startReading(), file: file, line: line)
        var frames = 0
        while vOut.copyNextSampleBuffer() != nil { frames += 1 }
        var audioBuffers = 0
        if let aOut { while aOut.copyNextSampleBuffer() != nil { audioBuffers += 1 } }
        XCTAssertNotEqual(reader.status, .failed, "\(String(describing: reader.error))", file: file, line: line)
        XCTAssertGreaterThan(frames, 130, "decoded video frames", file: file, line: line) // 6秒 × 24fps = 144
        if expectAudio { XCTAssertGreaterThan(audioBuffers, 10, file: file, line: line) }
        print("frames:", frames, "audio buffers:", audioBuffers, "duration:", duration)
    }

    func testTSWithAES128AndMasterPlaylist() async throws {
        try await runAndVerify("ts_aes/master.m3u8")
    }

    func testTSMediaPlaylistDirect() async throws {
        try await runAndVerify("ts_aes/media.m3u8")
    }

    func testFragmentedMP4() async throws {
        try await runAndVerify("fmp4/media.m3u8")
    }

    func testSeparateAudioRendition() async throws {
        try await runAndVerify("split/master.m3u8")
    }

    func testMissingPlaylistGivesHTTPLikeError() async throws {
        let dir = tempDir()
        let dl = HLSDownloader(url: fixtures.appendingPathComponent("nope/missing.m3u8"), headers: [:], workDir: dir)
        do {
            try await dl.download(to: dir.appendingPathComponent("o.mp4"))
            XCTFail("should throw")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testParserAttributesAndMaster() throws {
        let a = M3U8Parser.attributes(#"BANDWIDTH=1280000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720,AUDIO="aud""#)
        XCTAssertEqual(a["BANDWIDTH"], "1280000")
        XCTAssertEqual(a["CODECS"], "avc1.4d401f,mp4a.40.2")
        XCTAssertEqual(a["AUDIO"], "aud")

        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS="avc1.4d401f,mp4a.40.2"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,CODECS="hvc1.2.4.L153,mp4a.40.2"
        hevc/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS="avc1.640028,mp4a.40.2"
        high/index.m3u8?token=1
        """
        guard case .master(let variants, _) = try M3U8Parser.parse(master, baseURL: URL(string: "https://x.com/a/master.m3u8")!) else {
            return XCTFail("not master")
        }
        XCTAssertEqual(variants.count, 3)
        XCTAssertEqual(HLSDownloader.chooseVariant(variants)?.uri.absoluteString, "https://x.com/a/high/index.m3u8?token=1")
    }

    func testParserByteRangeAndKeys() throws {
        let media = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-KEY:METHOD=AES-128,URI="https://k.com/key"
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:1000@0
        all.ts
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:500
        all.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let segs, let ended) = try M3U8Parser.parse(media, baseURL: URL(string: "https://x.com/v/m.m3u8")!) else {
            return XCTFail("not media")
        }
        XCTAssertTrue(ended)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[1].byteRange, ByteRange(length: 500, offset: 1000))
        XCTAssertEqual(segs[1].sequence, 8)
        XCTAssertEqual(segs[0].key?.method, "AES-128")
        XCTAssertNil(segs[0].key?.iv)
    }
}
