import Foundation

public enum DoPFrameEncoderError: Error, Equatable, Sendable {
    case noChannels
    case mismatchedChannelLengths
    case incompleteDSDFrame
}

/// 把已归一化为 MSB-first 的逐通道 DSD 字节编码为交错 DoP 24-bit word。
public struct DoPFrameEncoder: Sendable {
    private var usesAlternateMarker = false

    public init() {}

    public mutating func reset() {
        usesAlternateMarker = false
    }

    public mutating func encode(dsdBytesByChannel channels: [[UInt8]]) throws -> [UInt32] {
        guard let byteCount = channels.first?.count else { throw DoPFrameEncoderError.noChannels }
        guard channels.allSatisfy({ $0.count == byteCount }) else {
            throw DoPFrameEncoderError.mismatchedChannelLengths
        }
        guard byteCount.isMultiple(of: 2) else { throw DoPFrameEncoderError.incompleteDSDFrame }

        let frameCount = byteCount / 2
        var output = [UInt32]()
        output.reserveCapacity(frameCount * channels.count)
        for frame in 0..<frameCount {
            let marker: UInt32 = usesAlternateMarker ? 0xFA : 0x05
            for channel in channels {
                let first = UInt32(channel[frame * 2])
                let second = UInt32(channel[frame * 2 + 1])
                // DoP 规定最早的 DSD sample 位于 16-bit payload 的 MSB；不能按主机小端字节序倒置时间。
                output.append((first << 8) | second | (marker << 16))
            }
            usesAlternateMarker.toggle()
        }
        return output
    }

    /// 将 24-bit DoP word 放入 HAL 声明的 32-bit 容器；调用方仍负责逐帧交错。
    public static func pack(_ word: UInt32, for format: HiFiAudioPhysicalFormat) -> UInt32 {
        // Core Audio USB 驱动的 32-bit packed DoP 路径同样使用高 24 位；与 PinPlayer 实测格式一致。
        let usesHigh24Bits = format.isAlignedHigh || (format.bitsPerChannel == 32 && format.isPacked)
        let aligned = usesHigh24Bits ? word << 8 : word
        return format.isBigEndian ? aligned.byteSwapped : aligned
    }

    /// 将高 24 位有效的 physical word 精确映射为 HAL Float32 virtual sample。
    /// 这些整数均为 256 的倍数，因此 Float32 的 24 位有效精度可以无损表示。
    public static func float32Sample(forPackedPhysicalWord word: UInt32) -> Float32 {
        Float32(Int32(bitPattern: word)) / 2_147_483_648
    }
}
