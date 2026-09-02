import Foundation

/// 在 HAL 输出时间线上统一 DoP marker，并为缺失的 source frame 填充合法静音。
struct DoPOutputTimeline {
    private let channelCount: Int
    private let markerMask: UInt32
    private let marker05: UInt32
    private let markerFA: UInt32
    private let silence05: Float32
    private let silenceFA: Float32
    private(set) var renderedFrameCount: UInt64 = 0

    init(format: HiFiAudioPhysicalFormat, channelCount: Int) {
        self.channelCount = channelCount
        markerMask = DoPFrameEncoder.pack(0x00FF_0000, for: format)
        marker05 = DoPFrameEncoder.pack(0x0005_0000, for: format)
        markerFA = DoPFrameEncoder.pack(0x00FA_0000, for: format)
        silence05 = DoPFrameEncoder.float32Sample(
            forPackedPhysicalWord: DoPFrameEncoder.pack(0x0005_6969, for: format)
        )
        silenceFA = DoPFrameEncoder.float32Sample(
            forPackedPhysicalWord: DoPFrameEncoder.pack(0x00FA_6969, for: format)
        )
    }

    mutating func render(
        interleavedSamples output: UnsafeMutablePointer<Float32>,
        sourceFrameCount: Int,
        totalFrameCount: Int
    ) {
        precondition(sourceFrameCount >= 0 && sourceFrameCount <= totalFrameCount)
        precondition(totalFrameCount >= 0)

        for frame in 0..<sourceFrameCount {
            let marker = markerWord(at: frame)
            for channel in 0..<channelCount {
                let index = frame * channelCount + channel
                let packed = DoPFrameEncoder.packedPhysicalWord(forFloat32Sample: output[index])
                output[index] = DoPFrameEncoder.float32Sample(
                    forPackedPhysicalWord: (packed & ~markerMask) | marker
                )
            }
        }
        for frame in sourceFrameCount..<totalFrameCount {
            let silence = markerWord(at: frame) == marker05 ? silence05 : silenceFA
            for channel in 0..<channelCount {
                output[frame * channelCount + channel] = silence
            }
        }
        renderedFrameCount += UInt64(totalFrameCount)
    }

    private func markerWord(at relativeFrame: Int) -> UInt32 {
        (renderedFrameCount + UInt64(relativeFrame)).isMultiple(of: 2) ? marker05 : markerFA
    }
}
