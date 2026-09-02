import Foundation
import Synchronization

/// 单生产者/单消费者的固定容量交错 Float32 帧缓冲；实时读取路径不分配内存也不加锁。
public final class SPSCFloatRingBuffer: @unchecked Sendable {
    public let capacityFrames: Int
    public let channelCount: Int

    public var availableFrames: Int {
        let read = readIndex.load(ordering: .acquiring)
        let written = writeIndex.load(ordering: .acquiring)
        return Int(written - read)
    }

    public var writableFrames: Int { capacityFrames - availableFrames }

    private let storage: UnsafeMutablePointer<Float32>
    private let readIndex = Atomic<UInt64>(0)
    private let writeIndex = Atomic<UInt64>(0)

    public init(capacityFrames: Int, channelCount: Int) {
        precondition(capacityFrames > 0 && channelCount > 0)
        self.capacityFrames = capacityFrames
        self.channelCount = channelCount
        storage = .allocate(capacity: capacityFrames * channelCount)
        storage.initialize(repeating: 0, count: capacityFrames * channelCount)
    }

    deinit {
        storage.deinitialize(count: capacityFrames * channelCount)
        storage.deallocate()
    }

    /// 非实时 producer 调用；空间不足时只写入当前可容纳的完整帧。
    @discardableResult
    public func write(interleavedSamples samples: UnsafeBufferPointer<Float32>) -> Int {
        guard samples.count.isMultiple(of: channelCount) else { return 0 }
        let read = readIndex.load(ordering: .acquiring)
        let written = writeIndex.load(ordering: .relaxed)
        let sourceFrames = samples.count / channelCount
        let freeFrames = capacityFrames - Int(written - read)
        let frameCount = min(sourceFrames, freeFrames)
        guard frameCount > 0 else { return 0 }

        for frame in 0..<frameCount {
            let destinationFrame = (Int(written) + frame) % capacityFrames
            for channel in 0..<channelCount {
                storage[destinationFrame * channelCount + channel] = samples[frame * channelCount + channel]
            }
        }
        writeIndex.store(written + UInt64(frameCount), ordering: .releasing)
        return frameCount
    }

    /// 实时 consumer 调用；返回实际读取帧数，剩余 output 内容由调用方决定如何填充。
    @discardableResult
    public func read(into output: UnsafeMutablePointer<Float32>, maximumFrames: Int) -> Int {
        guard maximumFrames > 0 else { return 0 }
        let read = readIndex.load(ordering: .relaxed)
        let written = writeIndex.load(ordering: .acquiring)
        let frameCount = min(maximumFrames, Int(written - read))
        guard frameCount > 0 else { return 0 }

        for frame in 0..<frameCount {
            let sourceFrame = (Int(read) + frame) % capacityFrames
            for channel in 0..<channelCount {
                output[frame * channelCount + channel] = storage[sourceFrame * channelCount + channel]
            }
        }
        readIndex.store(read + UInt64(frameCount), ordering: .releasing)
        return frameCount
    }
}
