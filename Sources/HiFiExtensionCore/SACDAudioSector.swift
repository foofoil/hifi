import Foundation

/// Scarlet Book 音频扇区：1 字节头 + packet info + frame info + 负载。
enum SACDAudioSector {
    static let size = 2048
    static let dsd64BytesPerChannelPerFrame = 4704
    static let audioDataType: UInt8 = 2

    struct Packet: Equatable {
        var startsFrame: Bool
        var dataType: UInt8
        var payload: Data
    }

    struct FrameInfo: Equatable {
        var minutes: UInt8
        var seconds: UInt8
        var frames: UInt8
    }

    static let audioMarkerPrefix = Data([0, 0, 0])
    static let audioRemainderRange = 1...3

    static func decode(_ sector: Data) throws -> (
        dstEncoded: Bool,
        packets: [Packet],
        frames: [FrameInfo],
        remainder: Data
    ) {
        let bytes = Array(sector)
        guard bytes.count == size else { throw DSDStreamError.truncatedAudioData }
        let header = bytes[0]
        let dstEncoded = (header & 0x01) != 0
        let frameInfoCount = Int((header >> 2) & 0x07)
        let packetInfoCount = Int((header >> 5) & 0x07)
        guard (0...7).contains(packetInfoCount), (0...7).contains(frameInfoCount) else {
            throw DSDStreamError.unsupportedFormat
        }
        if packetInfoCount == 0 {
            return (dstEncoded, [], [], Data())
        }
        var offset = 1
        var headers: [(startsFrame: Bool, dataType: UInt8, length: Int)] = []
        headers.reserveCapacity(packetInfoCount)
        for _ in 0..<packetInfoCount {
            guard offset + 2 <= bytes.count else { throw DSDStreamError.truncatedAudioData }
            let word = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            offset += 2
            headers.append((
                startsFrame: (word & 0x8000) != 0,
                dataType: UInt8((word >> 11) & 0x7),
                length: Int(word & 0x7FF)
            ))
        }
        var frames: [FrameInfo] = []
        // 未压缩扇区的 frame_info_count 只表示本扇区有几帧开始；4 字节表仅 DST 扇区存在。
        if dstEncoded {
            frames.reserveCapacity(frameInfoCount)
            for _ in 0..<frameInfoCount {
                guard offset + 4 <= bytes.count else { throw DSDStreamError.truncatedAudioData }
                frames.append(FrameInfo(minutes: bytes[offset], seconds: bytes[offset + 1], frames: bytes[offset + 2]))
                offset += 4
            }
        }
        var packets: [Packet] = []
        packets.reserveCapacity(headers.count)
        for header in headers {
            guard offset + header.length <= bytes.count else { throw DSDStreamError.truncatedAudioData }
            packets.append(
                Packet(
                    startsFrame: header.startsFrame,
                    dataType: header.dataType,
                    payload: Data(bytes[offset..<(offset + header.length)])
                )
            )
            offset += header.length
        }
        let remainder = offset < bytes.count ? Data(bytes[offset...]) : Data()
        return (dstEncoded, packets, frames, remainder)
    }

    /// 3-in-14 未压缩扇区：类型 2 包若以 `00 00 00` 开头则这 3 字节是标记不是 DSD；
    /// 包长度未覆盖的末尾 1…3 字节仍是音频，必须接上，否则会按帧注入 24 bit 全 0，听感像恒定电流声。
    static func dsdPayloads(
        packets: [Packet],
        remainder: Data
    ) -> [(startsFrame: Bool, payload: Data)] {
        var payloads: [(startsFrame: Bool, payload: Data)] = []
        payloads.reserveCapacity(packets.count + 1)
        let stripMarker = audioRemainderRange.contains(remainder.count)
        for packet in packets where packet.dataType == audioDataType {
            var payload = packet.payload
            if stripMarker, payload.starts(with: audioMarkerPrefix), payload.count > audioMarkerPrefix.count {
                payload = payload.dropFirst(audioMarkerPrefix.count)
            }
            guard !payload.isEmpty else { continue }
            payloads.append((packet.startsFrame, payload))
        }
        if stripMarker {
            payloads.append((false, remainder))
        }
        return payloads
    }

    static func encode(packets: [Packet], frames: [FrameInfo], dstEncoded: Bool = false) throws -> Data {
        guard packets.count <= 7, frames.count <= 7 else { throw DSDStreamError.unsupportedFormat }
        var header: UInt8 = 0
        if dstEncoded { header |= 0x01 }
        header |= UInt8(frames.count & 0x7) << 2
        header |= UInt8(packets.count & 0x7) << 5
        var data = Data([header])
        for packet in packets {
            guard packet.payload.count <= 0x7FF else { throw DSDStreamError.unsupportedFormat }
            var word = UInt16(packet.payload.count)
            word |= UInt16(packet.dataType & 0x7) << 11
            if packet.startsFrame { word |= 0x8000 }
            data.append(UInt8(word >> 8))
            data.append(UInt8(word & 0xFF))
        }
        if dstEncoded {
            for frame in frames {
                data.append(contentsOf: [frame.minutes, frame.seconds, frame.frames, 0])
            }
        }
        for packet in packets {
            data.append(packet.payload)
        }
        guard data.count <= size else { throw DSDStreamError.unsupportedFormat }
        if data.count < size {
            data.append(contentsOf: repeatElement(0 as UInt8, count: size - data.count))
        }
        return data
    }

    /// 把交织 DSD 帧切成接近 3-in-14 的扇区：每扇区约 2016 字节音频，帧边界可落在同一扇区的两个包里。
    static func packFrames(
        interleavedDSD: Data,
        channelCount: Int,
        startCueFrames: Int64
    ) throws -> [Data] {
        let frameBytes = dsd64BytesPerChannelPerFrame * channelCount
        guard channelCount > 0, interleavedDSD.count.isMultiple(of: frameBytes), frameBytes > 0 else {
            throw DSDStreamError.unsupportedFormat
        }
        let budget = 2016
        var sectors: [Data] = []
        var cue = startCueFrames
        var packets: [Packet] = []
        var used = 0
        var frameInfos: [FrameInfo] = []

        func flush() throws {
            guard !packets.isEmpty else { return }
            sectors.append(try encode(packets: packets, frames: frameInfos))
            packets = []
            used = 0
            frameInfos = []
        }

        var offset = 0
        while offset < interleavedDSD.count {
            var remaining = Data(interleavedDSD[offset..<(offset + frameBytes)])
            offset += frameBytes
            var isFirst = true
            while !remaining.isEmpty {
                if used >= budget {
                    try flush()
                }
                let chunk = remaining.prefix(budget - used)
                remaining.removeFirst(chunk.count)
                packets.append(Packet(startsFrame: isFirst, dataType: audioDataType, payload: Data(chunk)))
                if isFirst {
                    frameInfos = [
                        FrameInfo(
                            minutes: UInt8(min(255, cue / (60 * 75))),
                            seconds: UInt8((cue / 75) % 60),
                            frames: UInt8(cue % 75)
                        )
                    ]
                }
                used += chunk.count
                isFirst = false
            }
            cue += 1
        }
        try flush()
        return sectors
    }
}
