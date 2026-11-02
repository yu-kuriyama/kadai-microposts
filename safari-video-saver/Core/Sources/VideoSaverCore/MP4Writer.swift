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
        enum Item { case v(VideoSample), a(AudioSample) }
        var items: [(Int64, Item)] = []
        if videoInput != nil { items += video.map { ($0.dts, .v($0)) } }
        if audioInput != nil { items += audio.map { ($0.pts, .a($0)) } }
        items.sort { $0.0 < $1.0 }

        for (_, item) in items {
            switch item {
            case .v(let s):
                guard let input = videoInput, let fd = videoFormat else { continue }
                let pts = s.pts - base
                let dts = s.dts - base
                guard dts >= 0 || pts >= 0 else { continue }
                let buffer = try Self.videoBuffer(s, fd: fd, pts: max(0, pts), dts: max(0, dts))
                try wait(input)
                if !input.append(buffer) { throw HLSError.mux(writer.error?.localizedDescription ?? "映像の書き込みに失敗") }
            case .a(let s):
                guard let input = audioInput, let fd = audioFormat, let cfg = audioConfig else { continue }
                let pts = s.pts - base
                guard pts >= 0 else { continue }
                let buffer = try Self.audioBuffer(s, fd: fd, pts: pts, sampleRate: cfg.sampleRate)
                try wait(input)
                if !input.append(buffer) { throw HLSError.mux(writer.error?.localizedDescription ?? "音声の書き込みに失敗") }
            }
        }
    }

    func finish() async throws {
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw HLSError.mux(writer.error?.localizedDescription ?? "書き込みを完了できません")
        }
    }

    func cancel() {
        if started { writer.cancelWriting() }
    }

    private func wait(_ input: AVAssetWriterInput) throws {
        var tries = 0
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw HLSError.mux(writer.error?.localizedDescription ?? "書き込みエラー") }
            tries += 1
            if tries > 20000 { throw HLSError.mux("書き込みが進みません") } // 約40秒
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
        let cookie = c.audioSpecificConfig
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
