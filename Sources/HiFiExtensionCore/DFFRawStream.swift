import Foundation

/// 按 DSDIFF 交织布局读取 raw DSD；字节内已是 MSB-first，不再 bit-reverse。
public final class DFFRawStream: DSDStream {
    public let format: DSDStreamFormat
    public let sampleCount: UInt64

    public var samplePosition: UInt64 { min(bytePosition * 8, sampleCount) }

    private let fileHandle: FileHandle
    private let descriptor: DSDContainerDescriptor
    private let fileChannelCount: Int
    private let selectedChannels: [Int?]
    private let validByteFrames: UInt64
    private var bytePosition: UInt64 = 0

    public init(fileAt url: URL, outputMap: [Int?]? = nil) throws {
        let descriptor = try DSDContainerParser.parse(fileAt: url)
        guard descriptor.kind == .dff,
              descriptor.compression == .rawDSD,
              descriptor.channelCount > 0,
              let sampleCount = descriptor.sampleCount else {
            throw DSDStreamError.unsupportedFormat
        }
        let selectedChannels: [Int?]
        if let outputMap, !outputMap.isEmpty {
            selectedChannels = outputMap
        } else if descriptor.channelCount == 2 {
            selectedChannels = [0, 1]
        } else if let stereo = descriptor.stereoChannelIndices {
            selectedChannels = stereo.map { Optional($0) }
        } else {
            throw DSDStreamError.unsupportedFormat
        }
        guard selectedChannels.allSatisfy({ $0 == nil || (0..<descriptor.channelCount).contains($0!) }) else {
            throw DSDStreamError.unsupportedFormat
        }
        let fileChannelCount = descriptor.channelCount
        let frames = descriptor.audioDataByteCount / UInt64(fileChannelCount)
        guard frames > 0, descriptor.audioDataByteCount.isMultiple(of: UInt64(fileChannelCount)) else {
            throw DSDStreamError.truncatedAudioData
        }
        self.descriptor = descriptor
        self.sampleCount = sampleCount
        self.fileChannelCount = fileChannelCount
        self.selectedChannels = selectedChannels
        validByteFrames = min(frames, (sampleCount + 7) / 8)
        format = DSDStreamFormat(
            sampleRate: descriptor.sampleRate,
            channelCount: selectedChannels.count,
            bitOrder: .mostSignificantBitFirst
        )
        fileHandle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? fileHandle.close()
    }

    public func read(maximumByteFrames: Int) throws -> DSDByteChunk {
        guard maximumByteFrames > 0 else { throw DSDStreamError.invalidReadSize }
        let remaining = validByteFrames - bytePosition
        guard remaining > 0 else {
            return DSDByteChunk(bytesByChannel: Array(repeating: [], count: format.channelCount))
        }
        let requested = min(UInt64(maximumByteFrames), remaining)
        let byteCount = requested.multipliedReportingOverflow(by: UInt64(fileChannelCount))
        let frameOffset = bytePosition.multipliedReportingOverflow(by: UInt64(fileChannelCount))
        guard !byteCount.overflow, !frameOffset.overflow else { throw DSDStreamError.truncatedAudioData }
        let fileOffset = descriptor.audioDataOffset.addingReportingOverflow(frameOffset.partialValue)
        guard !fileOffset.overflow else { throw DSDStreamError.truncatedAudioData }

        try fileHandle.seek(toOffset: fileOffset.partialValue)
        guard let data = try fileHandle.read(upToCount: Int(byteCount.partialValue)),
              data.count == Int(byteCount.partialValue) else {
            throw DSDStreamError.truncatedAudioData
        }

        var output = Array(repeating: [UInt8](), count: selectedChannels.count)
        for channel in output.indices { output[channel].reserveCapacity(Int(requested)) }
        for frame in 0..<Int(requested) {
            let base = frame * fileChannelCount
            for (outputChannel, sourceChannel) in selectedChannels.enumerated() {
                if let sourceChannel {
                    output[outputChannel].append(data[base + sourceChannel])
                } else {
                    output[outputChannel].append(0x69)
                }
            }
        }
        bytePosition += requested
        return DSDByteChunk(bytesByChannel: output)
    }

    public func seek(toSample sample: UInt64) throws {
        guard sample <= sampleCount else { throw DSDStreamError.invalidSeekPosition }
        guard sample.isMultiple(of: 8) else { throw DSDStreamError.seekMustBeByteAligned }
        bytePosition = min(sample / 8, validByteFrames)
    }
}
