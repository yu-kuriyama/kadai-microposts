import Foundation

/// 映像1コマ分（H.264、AVCC 形式 = 4バイト長 + NAL）
public struct VideoSample {
    public var data: Data
    public var pts: Int64 // 90kHz
    public var dts: Int64 // 90kHz
    public var isSync: Bool
}

/// AAC 音声（ADTS ヘッダーを外した生フレームの集まり）
public struct AudioSample {
    public var frames: [Data]
    public var pts: Int64 // 90kHz（先頭フレーム）
}

public struct AACConfig: Equatable {
    public var objectType: Int
    public var sampleRateIndex: Int
    public var channels: Int

    static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    public var sampleRate: Int { sampleRateIndex < Self.rates.count ? Self.rates[sampleRateIndex] : 44100 }
    /// AudioSpecificConfig（2バイト）
    public var audioSpecificConfig: Data {
        let v = (objectType << 11) | (sampleRateIndex << 7) | (channels << 3)
        return Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}

/// 33bit タイムスタンプの巻き戻り補正
struct TimestampUnwrapper {
    private var last: Int64?
    private var offset: Int64 = 0
    mutating func unwrap(_ raw: Int64) -> Int64 {
        let wrap: Int64 = 1 << 33
        if let last {
            if raw + offset < last - wrap / 2 { offset += wrap } else if raw + offset > last + wrap / 2 { offset -= wrap }
        }
        let v = raw + offset
        last = v
        return v
    }
}

// MARK: - H.264

enum H264 {
    /// Annex-B（00 00 01 区切り）を NAL 単位に分割
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var i = 0
        var start = -1
        let n = bytes.count
        while i + 2 < n {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Data(bytes[start..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n {
            units.append(Data(bytes[start..<n]))
        }
        return units
    }
}

// MARK: - ADTS (AAC)

enum ADTS {
    /// ADTS フレーム列を分解
    static func parse(_ data: Data) -> (config: AACConfig?, frames: [Data]) {
        let b = [UInt8](data)
        var i = 0
        var frames: [Data] = []
        var config: AACConfig?
        while i + 7 <= b.count {
            guard b[i] == 0xFF, (b[i + 1] & 0xF6) == 0xF0 else { i += 1; continue }
            let protectionAbsent = b[i + 1] & 0x01
            let profile = Int((b[i + 2] >> 6) & 0x03)
            let freq = Int((b[i + 2] >> 2) & 0x0F)
            let ch = Int(((b[i + 2] & 0x01) << 2) | ((b[i + 3] >> 6) & 0x03))
            let len = (Int(b[i + 3] & 0x03) << 11) | (Int(b[i + 4]) << 3) | Int((b[i + 5] >> 5) & 0x07)
            let header = protectionAbsent == 1 ? 7 : 9
            guard len > header, i + len <= b.count else { break }
            if config == nil {
                config = AACConfig(objectType: profile + 1, sampleRateIndex: freq, channels: ch)
            }
            frames.append(Data(b[(i + header)..<(i + len)]))
            i += len
        }
        return (config, frames)
    }

    /// パック化オーディオ（.aac セグメント）の ID3 タグから開始時刻を取り出す
    static func stripID3(_ data: Data) -> (pts: Int64?, rest: Data) {
        let b = [UInt8](data)
        var i = 0
        var pts: Int64?
        while i + 10 <= b.count, b[i] == 0x49, b[i + 1] == 0x44, b[i + 2] == 0x33 { // "ID3"
            let size = (Int(b[i + 6] & 0x7F) << 21) | (Int(b[i + 7] & 0x7F) << 14) | (Int(b[i + 8] & 0x7F) << 7) | Int(b[i + 9] & 0x7F)
            let end = min(b.count, i + 10 + size)
            let tag = Data(b[i..<end])
            if let r = tag.range(of: Data("com.apple.streaming.transportStreamTimestamp".utf8)) {
                let p = r.upperBound + 1 // 終端の NUL を飛ばす
                let tb = [UInt8](tag)
                let local = p - tag.startIndex
                if local + 8 <= tb.count {
                    var v: Int64 = 0
                    for k in 0..<8 { v = (v << 8) | Int64(tb[local + k]) }
                    pts = v & ((1 << 33) - 1)
                }
            }
            i = end
        }
        return (pts, Data(b[i...]))
    }
}

// MARK: - MPEG-TS

/// MPEG-TS を映像（H.264）と音声（AAC）に分解する。セグメントを順番に feed していく。
public final class TSDemuxer {
    public private(set) var videoSamples: [VideoSample] = []
    public private(set) var audioSamples: [AudioSample] = []
    public private(set) var sps: Data?
    public private(set) var pps: Data?
    public private(set) var aacConfig: AACConfig?
    public private(set) var unsupportedVideo: String?

    private var leftover = Data()
    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var pes: [Int: Data] = [:]
    private var videoTS = TimestampUnwrapper()
    private var videoDTS = TimestampUnwrapper()
    private var audioTS = TimestampUnwrapper()

    public init() {}

    public var hasVideo: Bool { videoPID != nil }
    public var hasAudio: Bool { audioPID != nil }

    public func feed(_ data: Data) {
        var buf = leftover + data
        leftover = Data()
        var bytes = [UInt8](buf)
        buf = Data()
        var i = 0
        while i + 188 <= bytes.count {
            if bytes[i] != 0x47 { i += 1; continue }
            packet(bytes, i)
            i += 188
        }
        if i < bytes.count { leftover = Data(bytes[i...]) }
        bytes.removeAll()
    }

    /// 最後に呼ぶ（途中の PES を確定させる）
    public func flush() {
        for (pid, data) in pes where !data.isEmpty { handlePES(pid: pid, data) }
        pes.removeAll()
    }

    /// これまでに取り出したサンプルを受け取って空にする
    public func takeSamples() -> (video: [VideoSample], audio: [AudioSample]) {
        defer {
            videoSamples.removeAll(keepingCapacity: true)
            audioSamples.removeAll(keepingCapacity: true)
        }
        return (videoSamples, audioSamples)
    }

    private func packet(_ b: [UInt8], _ o: Int) {
        let pusi = (b[o + 1] & 0x40) != 0
        let pid = (Int(b[o + 1] & 0x1F) << 8) | Int(b[o + 2])
        let afc = (b[o + 3] >> 4) & 0x03
        var p = o + 4
        if afc == 2 || afc == 0 { return }
        if afc == 3 { p += 1 + Int(b[o + 4]) }
        guard p < o + 188 else { return }
        let payload = b[p..<(o + 188)]

        if pid == 0 {
            if pusi { parsePAT(Array(payload)) }
        } else if pid == pmtPID {
            if pusi { parsePMT(Array(payload)) }
        } else if pid == videoPID || pid == audioPID {
            if pusi {
                if let prev = pes[pid], !prev.isEmpty { handlePES(pid: pid, prev) }
                pes[pid] = Data(payload)
            } else if pes[pid] != nil {
                pes[pid]!.append(contentsOf: payload)
            }
        }
    }

    private func parsePAT(_ p: [UInt8]) {
        guard !p.isEmpty else { return }
        let s = 1 + Int(p[0])
        guard s + 8 <= p.count else { return }
        let sectionLength = (Int(p[s + 1] & 0x0F) << 8) | Int(p[s + 2])
        var i = s + 8
        let end = min(p.count, s + 3 + sectionLength - 4)
        while i + 4 <= end {
            let program = (Int(p[i]) << 8) | Int(p[i + 1])
            let pid = (Int(p[i + 2] & 0x1F) << 8) | Int(p[i + 3])
            if program != 0 { pmtPID = pid; return }
            i += 4
        }
    }

    private func parsePMT(_ p: [UInt8]) {
        guard !p.isEmpty else { return }
        let s = 1 + Int(p[0])
        guard s + 12 <= p.count else { return }
        let sectionLength = (Int(p[s + 1] & 0x0F) << 8) | Int(p[s + 2])
        let infoLength = (Int(p[s + 10] & 0x0F) << 8) | Int(p[s + 11])
        var i = s + 12 + infoLength
        let end = min(p.count, s + 3 + sectionLength - 4)
        while i + 5 <= end {
            let type = p[i]
            let pid = (Int(p[i + 1] & 0x1F) << 8) | Int(p[i + 2])
            let esInfo = (Int(p[i + 3] & 0x0F) << 8) | Int(p[i + 4])
            switch type {
            case 0x1B: if videoPID == nil { videoPID = pid }
            case 0x24: unsupportedVideo = "HEVC(H.265)"
            case 0x0F: if audioPID == nil { audioPID = pid }
            default: break
            }
            i += 5 + esInfo
        }
    }

    private func handlePES(pid: Int, _ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return }
        let flags = (b[7] >> 6) & 0x03
        let headerLength = Int(b[8])
        let payloadStart = 9 + headerLength
        guard payloadStart <= b.count else { return }
        func ts(_ k: Int) -> Int64 {
            (Int64(b[k] >> 1) & 0x07) << 30 | Int64(b[k + 1]) << 22 | Int64(b[k + 2] >> 1) << 15
                | Int64(b[k + 3]) << 7 | Int64(b[k + 4] >> 1)
        }
        var pts: Int64?
        var dts: Int64?
        if flags & 0x02 != 0, b.count >= 14 { pts = ts(9) }
        if flags == 0x03, b.count >= 19 { dts = ts(14) }
        let payload = Data(b[payloadStart...])

        if pid == videoPID {
            guard let rawPTS = pts else { return }
            let p = videoTS.unwrap(rawPTS)
            let dd = videoDTS.unwrap(dts ?? rawPTS)
            handleVideo(payload, pts: p, dts: dd)
        } else if pid == audioPID {
            let (config, frames) = ADTS.parse(payload)
            if aacConfig == nil { aacConfig = config }
            guard !frames.isEmpty, let rawPTS = pts else { return }
            audioSamples.append(AudioSample(frames: frames, pts: audioTS.unwrap(rawPTS)))
        }
    }

    private func handleVideo(_ payload: Data, pts: Int64, dts: Int64) {
        var out = Data()
        var sync = false
        for nal in H264.nalUnits(payload) {
            guard let first = nal.first else { continue }
            let type = first & 0x1F
            switch type {
            case 7: if sps == nil { sps = nal }; continue
            case 8: if pps == nil { pps = nal }; continue
            case 9: continue // AUD
            case 5: sync = true
            default: break
            }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        guard !out.isEmpty else { return }
        videoSamples.append(VideoSample(data: out, pts: pts, dts: dts, isSync: sync))
    }
}

/// パック化オーディオ（ID3 + ADTS の .aac セグメント）用
public final class PackedAudioDemuxer {
    public private(set) var aacConfig: AACConfig?
    private var nextPTS: Int64 = 0
    private var samples: [AudioSample] = []

    public init() {}

    public func feed(_ data: Data) {
        let (pts, rest) = ADTS.stripID3(data)
        let (config, frames) = ADTS.parse(rest)
        if aacConfig == nil { aacConfig = config }
        guard !frames.isEmpty, let cfg = aacConfig else { return }
        let start = pts ?? nextPTS
        samples.append(AudioSample(frames: frames, pts: start))
        nextPTS = start + Int64(frames.count) * 1024 * 90000 / Int64(cfg.sampleRate)
    }

    public func takeSamples() -> [AudioSample] {
        defer { samples.removeAll() }
        return samples
    }
}
