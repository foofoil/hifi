import Foundation

/// 从 SACD ISO 的 Stereo Area 读取一条未压缩曲目，输出逐声道 MSB-first DSD，布局与 raw DFF 相同。
public final class SACDRawStream: DSDStream {
    public let format: DSDStreamFormat
    public let sampleCount: UInt64

    public var samplePosition: UInt64 { min(consumedSamples, sampleCount) }

    private let fileHandle: FileHandle
    private let area: SACDArea
    private let track: SACDTrack
    private let bytesPerFrame: Int
    private let samplesPerFrame: UInt64
    private let lastLSN: UInt32
    private var nextLSN: UInt32
    private var pending = DSDByteChunk(bytesByChannel: [])
    private var pendingOffset = 0
    private var consumedSamples: UInt64 = 0
    private var assembling = Data()
    private var waitingForFrameStart = true
    private var sequentialReads = false

    public init(fileAt url: URL, disc: SACDDisc, trackNumber: Int) throws {
        guard let pair = disc.track(number: trackNumber) else { throw SACDISOError.invalidFormat }
        let area = pair.0
        let track = pair.1
        guard area.frameFormat != .dst else { throw SACDISOError.unsupportedFrameFormat }
        guard area.channelCount > 0, track.lengthLSN > 0 else { throw SACDISOError.invalidFormat }
        let sampleCount = track.sampleCount(sampleRate: area.sampleRate)
        guard sampleCount > 0 else { throw SACDISOError.invalidFormat }
        self.area = area
        self.track = track
        self.sampleCount = sampleCount
        bytesPerFrame = SACDAudioSector.dsd64BytesPerChannelPerFrame * area.channelCount
        samplesPerFrame = UInt64(area.sampleRate / SACDISOParser.frameRate)
        lastLSN = track.startLSN + track.lengthLSN
        nextLSN = track.startLSN
        format = DSDStreamFormat(
            sampleRate: area.sampleRate,
            channelCount: area.channelCount,
            bitOrder: .mostSignificantBitFirst
        )
        pending = DSDByteChunk(bytesByChannel: Array(repeating: [], count: area.channelCount))
        fileHandle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? fileHandle.close()
    }

    public func read(maximumByteFrames: Int) throws -> DSDByteChunk {
        guard maximumByteFrames > 0 else { throw DSDStreamError.invalidReadSize }
        let remainingSamples = sampleCount - consumedSamples
        guard remainingSamples > 0 else {
            return DSDByteChunk(bytesByChannel: Array(repeating: [], count: format.channelCount))
        }
        let requested = min(UInt64(maximumByteFrames), (remainingSamples + 7) / 8)
        var output = Array(repeating: [UInt8](), count: format.channelCount)
        for channel in output.indices { output[channel].reserveCapacity(Int(requested)) }
        var collected: UInt64 = 0
        while collected < requested {
            try fillPendingIfNeeded()
            let available = pending.byteFrameCount - pendingOffset
            if available <= 0 { break }
            let take = min(Int(requested - collected), available)
            for channel in output.indices {
                output[channel].append(contentsOf: pending.bytesByChannel[channel][pendingOffset..<(pendingOffset + take)])
            }
            pendingOffset += take
            collected += UInt64(take)
        }
        consumedSamples = min(sampleCount, consumedSamples + collected * 8)
        return DSDByteChunk(bytesByChannel: output)
    }

    public func seek(toSample sample: UInt64) throws {
        guard sample <= sampleCount else { throw DSDStreamError.invalidSeekPosition }
        guard sample.isMultiple(of: 8) else { throw DSDStreamError.seekMustBeByteAligned }
        let frameIndex = samplesPerFrame == 0 ? 0 : sample / samplesPerFrame
        let sampleInFrame = samplesPerFrame == 0 ? 0 : sample % samplesPerFrame
        jump(toFrameIndex: frameIndex)
        try fillPendingIfNeeded()
        let skipBytes = Int(sampleInFrame / 8)
        if pending.byteFrameCount > 0 {
            pendingOffset = min(skipBytes, pending.byteFrameCount)
        }
        consumedSamples = min(sampleCount, frameIndex * samplesPerFrame + UInt64(pendingOffset) * 8)
    }

    private func jump(toFrameIndex frameIndex: UInt64) {
        // 未压缩立体声约 14 扇区 / 3 帧；先落到附近再靠 frame_start 对齐。
        let sectorOffset = frameIndex.multipliedReportingOverflow(by: 14)
        let estimated = sectorOffset.overflow ? UInt64(track.lengthLSN) : sectorOffset.partialValue / 3
        let clamped = min(UInt32(clamping: estimated), track.lengthLSN)
        nextLSN = track.startLSN + clamped
        assembling = Data()
        waitingForFrameStart = true
        sequentialReads = false
        pending = DSDByteChunk(bytesByChannel: Array(repeating: [], count: format.channelCount))
        pendingOffset = 0
        consumedSamples = 0
    }

    private func fillPendingIfNeeded() throws {
        if pendingOffset < pending.byteFrameCount { return }
        pendingOffset = 0
        pending = DSDByteChunk(bytesByChannel: Array(repeating: [], count: format.channelCount))
        while pending.byteFrameCount == 0 {
            if assembling.count >= bytesPerFrame {
                pending = try deinterleaveFrame(assembling.prefix(bytesPerFrame))
                assembling.removeFirst(bytesPerFrame)
                return
            }
            guard nextLSN < lastLSN else { return }
            let sector = try readSector(nextLSN)
            nextLSN += 1
            let decoded: (
                dstEncoded: Bool,
                packets: [SACDAudioSector.Packet],
                frames: [SACDAudioSector.FrameInfo],
                remainder: Data
            )
            do {
                decoded = try SACDAudioSector.decode(sector)
            } catch {
                continue
            }
            if decoded.dstEncoded { throw SACDISOError.unsupportedFrameFormat }
            // 必须先吃完本扇区所有音频包和 1…3 字节尾巴，不能在凑满一帧时 return，
            // 否则同一扇区里下一帧的开头会被丢掉，听感就是一截一截。
            for piece in SACDAudioSector.dsdPayloads(packets: decoded.packets, remainder: decoded.remainder) {
                if piece.startsFrame && waitingForFrameStart {
                    assembling = Data(piece.payload)
                    waitingForFrameStart = false
                } else if waitingForFrameStart {
                    continue
                } else {
                    assembling.append(piece.payload)
                }
            }
        }
    }

    private func readSector(_ lsn: UInt32) throws -> Data {
        if !sequentialReads {
            try fileHandle.seek(toOffset: UInt64(lsn) * UInt64(SACDISOParser.sectorSize))
            sequentialReads = true
        }
        guard let data = try fileHandle.read(upToCount: SACDISOParser.sectorSize),
              data.count == SACDISOParser.sectorSize else {
            sequentialReads = false
            throw SACDISOError.truncated
        }
        return data
    }

    private func deinterleaveFrame(_ frame: Data.SubSequence) throws -> DSDByteChunk {
        let channels = format.channelCount
        let byteFrames = SACDAudioSector.dsd64BytesPerChannelPerFrame
        guard frame.count >= byteFrames * channels else { throw SACDISOError.truncated }
        var output = Array(repeating: [UInt8](), count: channels)
        for channel in output.indices { output[channel].reserveCapacity(byteFrames) }
        let bytes = Array(frame.prefix(byteFrames * channels))
        // Scarlet Book / DFF：按字节 LRLR，不是 16-bit 字交错。
        for index in 0..<byteFrames {
            let base = index * channels
            for channel in 0..<channels {
                output[channel].append(bytes[base + channel])
            }
        }
        return DSDByteChunk(bytesByChannel: output)
    }
}
