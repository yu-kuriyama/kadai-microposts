import AVFoundation
import CoreMedia
import Foundation

/// H.264 / AAC のサンプルを再エンコードせずに mp4 に書き込む
final class MP4Writer {
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    private var audioConfig: AACConfig?
    private var base: Int64?
    private var started = false

    init(output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
    }

    var isStarted: Bool { started }

    /// 最初のセグメントを読んだ後、含まれるトラックの情報で書き込みを始める
    func start(sps: Data?, pps: Data?, aac: AACConfig?, base: Int64) throws {
        if let sps, let pps {
            let fd = try Self.h264Format(sps: sps, pps: pps)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw HLSError.mux("映像トラックを追加できません") }
            writer.add(input)
            videoInput = input
            videoFormat = fd
        }
        if let aac {
            let fd = try Self.aacFormat(aac)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fd)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw HLSError.mux("音声トラックを追加できません") }
            writer.add(input)
            audioInput = input
            audioFormat = fd
            audioConfig = aac
        }
        guard videoInput != nil || audioInput != nil else { throw HLSError.noMedia }
        guard writer.startWriting() else {
            throw HLSError.mux(writer.error?.localizedDescription ?? "書き込みを開始できません")
        }
        writer.startSession(atSourceTime: .zero)
        self.base = base
        started = true
    }

    /// 1セグメント分のサンプルを時刻順に書き込む
    func append(video: [VideoSample], audio: [AudioSample]) throws {
        guard started, let base else { return }
        if videoInput != nil, let fd = videoFormat {
            for s in video {
                let pts = s.pts - base
                let dts = s.dts - base
                guard dts >= 0 || pts >= 0 else { continue }
                pendingVideo.append(try Self.videoBuffer(s, fd: fd, pts: max(0, pts), dts: max(0, dts)))
            }
        }
        if audioInput != nil, let fd = audioFormat, let cfg = audioConfig {
            for s in audio {
                let pts = s.pts - base
                guard pts >= 0 else { continue }
                pendingAudio.append(try Self.audioBuffer(s, fd: fd, pts: pts, sampleRate: cfg.sampleRate))
            }
        }
        try drain(final: false)
    }

    func finish() async throws {
        if started { try drain(final: true) }
        if videoInput.map({ !finished.contains(ObjectIdentifier($0)) }) == true { videoInput?.markAsFinished() }
        if audioInput.map({ !finished.contains(ObjectIdentifier($0)) }) == true { audioInput?.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed {
            throw HLSError.mux(writer.error?.localizedDescription ?? "書き込みを完了できません")
        }
    }

    func cancel() {
        if started { writer.cancelWriting() }
    }

    // AVAssetWriter は映像と音声を交互に並べるため、片方のトラックを先に進めすぎると
    // もう片方のデータが来るまで isReadyForMoreMediaData が false のままになる。
    // 待っている側のデータがまだ無い時は、次のセグメントが来るまで書き込みを保留する。
    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var finished: Set<ObjectIdentifier> = []

    private func drain(final: Bool) throws {
        var idle = 0
        while !pendingVideo.isEmpty || !pendingAudio.isEmpty {
            if writer.status == .failed { throw HLSError.mux(writer.error?.localizedDescription ?? "書き込みエラー") }
            var progressed = false
            for (input, isVideo) in [(videoInput, true), (audioInput, false)] {
                guard let input else { continue }
                while input.isReadyForMoreMediaData {
                    let buffer: CMSampleBuffer
                    if isVideo {
                        guard !pendingVideo.isEmpty else { break }
                        buffer = pendingVideo.removeFirst()
                    } else {
                        guard !pendingAudio.isEmpty else { break }
                        buffer = pendingAudio.removeFirst()
                    }
                    if !input.append(buffer) {
                        throw HLSError.mux(writer.error?.localizedDescription ?? (isVideo ? "映像の書き込みに失敗" : "音声の書き込みに失敗"))
                    }
                    progressed = true
                }
            }
            if progressed { idle = 0; continue }

            // 進めなかった：データが尽きた側を待っているなら
            let starved = [(videoInput, pendingVideo.isEmpty), (audioInput, pendingAudio.isEmpty)]
                .compactMap { $0.0 != nil && $0.1 ? $0.0 : nil }
                .filter { !finished.contains(ObjectIdentifier($0)) }
            if !starved.isEmpty {
                // 途中なら次のセグメントを待つ。最後ならその側を終わらせて残りを流す
                guard final else { return }
                for input in starved {
                    input.markAsFinished()
                    finished.insert(ObjectIdentifier(input))
                }
                continue
            }
            idle += 1
            if idle > 20000 { throw HLSError.mux("書き込みが進みません") } // 約40秒
            usleep(2000)
        }
    }

    // MARK: - CoreMedia の組み立て

    static func h264Format(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var fd: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers: [UnsafePointer<UInt8>] = [
                    s.bindMemory(to: UInt8.self).baseAddress!,
                    p.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let fd else { throw HLSError.mux("映像の形式を読み取れません (\(status))") }
        return fd
    }

    static func aacFormat(_ c: AACConfig) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(c.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(c.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, c.channels)), mBitsPerChannel: 0, mReserved: 0)
        // AudioSpecificConfig そのままだと esds が壊れて AVFoundation が音声トラックを読めない。
        // ES_Descriptor で包んだ形（esds の中身）を渡す
        let cookie = esdsCookie(c.audioSpecificConfig)
        var fd: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { ptr in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: ptr.baseAddress,
                extensions: nil, formatDescriptionOut: &fd)
        }
        guard status == noErr, let fd else { throw HLSError.mux("音声の形式を読み取れません (\(status))") }
        return fd
    }

    /// ES_Descriptor(0x03) > DecoderConfigDescriptor(0x04) > DecoderSpecificInfo(0x05) = ASC, SLConfig(0x06)
    static func esdsCookie(_ asc: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            var d = Data([tag])
            let n = body.count
            d.append(contentsOf: [UInt8(0x80 | ((n >> 21) & 0x7F)), UInt8(0x80 | ((n >> 14) & 0x7F)),
                                  UInt8(0x80 | ((n >> 7) & 0x7F)), UInt8(n & 0x7F)])
            d.append(body)
            return d
        }
        var decoderConfig = Data([0x40, 0x15]) // MPEG-4 Audio, AudioStream
        decoderConfig.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) // bufferSize / maxBitrate / avgBitrate
        decoderConfig.append(descriptor(0x05, asc))
        var es = Data([0, 0, 0]) // ES_ID, flags
        es.append(descriptor(0x04, decoderConfig))
        es.append(descriptor(0x06, Data([0x02])))
        return descriptor(0x03, es)
    }

    private static func blockBuffer(_ data: Data) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw HLSError.mux("メモリ確保に失敗 (\(status))") }
        status = data.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw HLSError.mux("データのコピーに失敗 (\(status))") }
        return block
    }

    private static func videoBuffer(_ s: VideoSample, fd: CMVideoFormatDescription, pts: Int64, dts: Int64) throws -> CMSampleBuffer {
        let block = try blockBuffer(s.data)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 90000),
            decodeTimeStamp: CMTime(value: dts, timescale: 90000))
        var size = s.data.count
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw HLSError.mux("映像サンプルの作成に失敗 (\(status))") }
        if !s.isSync, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }

    private static func audioBuffer(_ s: AudioSample, fd: CMAudioFormatDescription, pts: Int64, sampleRate: Int) throws -> CMSampleBuffer {
        var data = Data()
        var descriptions: [AudioStreamPacketDescription] = []
        for f in s.frames {
            descriptions.append(AudioStreamPacketDescription(
                mStartOffset: Int64(data.count), mVariableFramesInPacket: 0, mDataByteSize: UInt32(f.count)))
            data.append(f)
        }
        let block = try blockBuffer(data)
        var buffer: CMSampleBuffer?
        let time = CMTimeConvertScale(CMTime(value: pts, timescale: 90000), timescale: Int32(sampleRate), method: .roundHalfAwayFromZero)
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
            sampleCount: descriptions.count, presentationTimeStamp: time,
            packetDescriptions: descriptions, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw HLSError.mux("音声サンプルの作成に失敗 (\(status))") }
        return buffer
    }
}
