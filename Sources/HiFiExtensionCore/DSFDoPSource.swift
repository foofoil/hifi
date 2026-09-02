import Foundation

/// 在非实时 worker 上把 DSF 的逐声道 DSD 字节转换为 HAL Float32 virtual frames。
public final class DSFDoPSource {
    public let channelCount: Int
    public let dsdSampleRate: Int

    public var samplePosition: UInt64 { stream.samplePosition }
    public var sampleCount: UInt64 { stream.sampleCount }

    private let stream: DSFRawStream
    private let physicalFormat: HiFiAudioPhysicalFormat
    private var encoder = DoPFrameEncoder()

    public init(fileAt url: URL, physicalFormat: HiFiAudioPhysicalFormat) throws {
        stream = try DSFRawStream(fileAt: url)
        guard stream.format.channelCount == Int(physicalFormat.channelCount) else {
            throw DSDStreamError.unsupportedFormat
        }
        channelCount = stream.format.channelCount
        dsdSampleRate = stream.format.sampleRate
        self.physicalFormat = physicalFormat
    }

    public func read(maximumDoPFrames: Int) throws -> [Float32] {
        guard maximumDoPFrames > 0 else { throw DSDStreamError.invalidReadSize }
        let chunk = try stream.read(maximumByteFrames: maximumDoPFrames * 2)
        guard !chunk.isEmpty else { return [] }

        var channels = chunk.bytesByChannel
        // DoP 每帧需要两个 DSD 字节；只在文件末尾补一个静音字节，不把 padding 带入普通读取。
        if chunk.byteFrameCount.isMultiple(of: 2) == false {
            for channel in channels.indices { channels[channel].append(0x69) }
        }
        return try encoder.encode(dsdBytesByChannel: channels).map {
            let packed = DoPFrameEncoder.pack($0, for: physicalFormat)
            return DoPFrameEncoder.float32Sample(forPackedPhysicalWord: packed)
        }
    }

    public func seek(toSample sample: UInt64) throws {
        try stream.seek(toSample: sample)
        encoder.reset()
    }
}
