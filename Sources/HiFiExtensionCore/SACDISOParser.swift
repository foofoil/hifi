import Foundation

public enum SACDFrameFormat: Equatable, Sendable {
    case dst
    case dsd3In14
    case dsd3In16
}

public enum SACDISOError: Error, Equatable, Sendable {
    case notSACD
    case truncated
    case invalidFormat
    case missingStereoArea
    case unsupportedFrameFormat
}

public struct SACDTrack: Equatable, Sendable {
    public let number: Int
    public let title: String?
    public let artist: String?
    public let composer: String?
    public let startCueFrames: Int64
    public let durationCueFrames: Int64
    public let startLSN: UInt32
    public let lengthLSN: UInt32

    public var endCueFrames: Int64 { startCueFrames + durationCueFrames }

    public func sampleCount(sampleRate: Int) -> UInt64 {
        guard sampleRate > 0, sampleRate.isMultiple(of: SACDISOParser.frameRate) else { return 0 }
        return UInt64(max(0, durationCueFrames)) * UInt64(sampleRate / SACDISOParser.frameRate)
    }
}

public struct SACDArea: Equatable, Sendable {
    public let id: String
    public let sampleRate: Int
    public let channelCount: Int
    public let frameFormat: SACDFrameFormat
    public let tracks: [SACDTrack]
}

public struct SACDDisc: Equatable, Sendable {
    public let albumTitle: String?
    public let albumArtist: String?
    public let year: String?
    public let areas: [SACDArea]

    public var stereoArea: SACDArea? {
        areas.first { $0.id == SACDISOParser.magicStereoTOC && $0.channelCount == 2 }
            ?? areas.first { $0.channelCount == 2 }
    }

    public var displayTitle: String? {
        let title = albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false) ? title : nil
    }

    public func track(number: Int, in area: SACDArea? = nil) -> (SACDArea, SACDTrack)? {
        let area = area ?? stereoArea
        guard let area, let track = area.tracks.first(where: { $0.number == number }) else { return nil }
        return (area, track)
    }

    public func containerDescriptor(trackNumber: Int? = nil) throws -> DSDContainerDescriptor {
        guard let area = stereoArea else { throw SACDISOError.missingStereoArea }
        guard area.frameFormat != .dst else { throw SACDISOError.unsupportedFrameFormat }
        let track: SACDTrack
        if let trackNumber {
            guard let match = area.tracks.first(where: { $0.number == trackNumber }) else {
                throw SACDISOError.invalidFormat
            }
            track = match
        } else {
            guard let first = area.tracks.first else { throw SACDISOError.invalidFormat }
            track = first
        }
        let sampleCount = track.sampleCount(sampleRate: area.sampleRate)
        guard sampleCount > 0 else { throw SACDISOError.invalidFormat }
        return DSDContainerDescriptor(
            kind: .sacd,
            compression: .rawDSD,
            sampleRate: area.sampleRate,
            channelCount: area.channelCount,
            sampleCount: sampleCount,
            blockSizePerChannel: nil,
            bitOrder: .mostSignificantBitFirst,
            audioDataOffset: UInt64(track.startLSN) * UInt64(SACDISOParser.sectorSize),
            audioDataByteCount: UInt64(track.lengthLSN) * UInt64(SACDISOParser.sectorSize),
            metadataOffset: nil,
            channelLabels: area.channelCount == 2 ? ["SLFT", "SRGT"] : []
        )
    }
}

public enum SACDISOParser {
    public static let sectorSize = 2048
    public static let masterTOCStartLSN: UInt32 = 510
    public static let masterTOCSectorCount = 10
    public static let frameRate = 75
    public static let dsd64SampleRate = 2_822_400
    public static let magicMasterTOC = "SACDMTOC"
    public static let magicStereoTOC = "TWOCHTOC"
    public static let magicMultiTOC = "MULCHTOC"
    public static let magicTrackListOffset = "SACDTRL1"
    public static let magicTrackListTime = "SACDTRL2"
    public static let magicTrackText = "SACDTTxt"
    public static let magicMasterText = "SACDText"

    public static func sniff(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return sniff(handle)
    }

    public static func sniff(_ data: Data) -> Bool {
        let offset = Int(masterTOCStartLSN) * sectorSize
        guard data.count >= offset + 8 else { return false }
        return data[offset..<(offset + 8)] == Data(magicMasterTOC.utf8)
    }

    public static func parse(fileAt url: URL) throws -> SACDDisc {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard sniff(handle) else { throw SACDISOError.notSACD }
        let master = try readSectors(handle, start: masterTOCStartLSN, count: masterTOCSectorCount)
        return try parse(masterTOC: master, readArea: { start, count in
            try readSectors(handle, start: start, count: count)
        })
    }

    public static func parse(_ data: Data) throws -> SACDDisc {
        guard sniff(data) else { throw SACDISOError.notSACD }
        return try parse(masterTOC: try sectorRange(data, start: masterTOCStartLSN, count: masterTOCSectorCount)) { start, count in
            try sectorRange(data, start: start, count: count)
        }
    }

    private static func sniff(_ handle: FileHandle) -> Bool {
        let offset = UInt64(masterTOCStartLSN) * UInt64(sectorSize)
        guard let size = try? handle.seekToEnd(), size >= offset + 8 else { return false }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: 8), data.count == 8 else { return false }
            return data == Data(magicMasterTOC.utf8)
        } catch {
            return false
        }
    }

    private static func parse(
        masterTOC: Data,
        readArea: (UInt32, Int) throws -> Data
    ) throws -> SACDDisc {
        guard masterTOC.count >= sectorSize,
              ascii(masterTOC, at: 0, count: 8) == magicMasterTOC else {
            throw SACDISOError.notSACD
        }

        let stereoStart = try uint32BE(masterTOC, at: 64)
        let multiStart = try uint32BE(masterTOC, at: 72)
        let stereoSize = Int(try uint16BE(masterTOC, at: 84))
        let multiSize = Int(try uint16BE(masterTOC, at: 86))
        let yearValue = try uint16BE(masterTOC, at: 120)
        let year = yearValue > 0 ? String(yearValue) : nil

        let text = parseMasterText(masterTOC)
        var areas: [SACDArea] = []
        if stereoStart > 0, stereoSize > 0 {
            let data = try readArea(stereoStart, min(stereoSize, 96))
            if let area = try parseArea(data, albumArtist: text.artist) {
                areas.append(area)
            }
        }
        if multiStart > 0, multiSize > 0 {
            let data = try readArea(multiStart, min(multiSize, 96))
            if let area = try parseArea(data, albumArtist: text.artist) {
                areas.append(area)
            }
        }
        guard areas.contains(where: { $0.channelCount == 2 }) else {
            throw SACDISOError.missingStereoArea
        }
        return SACDDisc(
            albumTitle: text.title,
            albumArtist: text.artist,
            year: year,
            areas: areas
        )
    }

    private static func parseArea(_ data: Data, albumArtist: String?) throws -> SACDArea? {
        guard data.count >= sectorSize else { throw SACDISOError.truncated }
        let id = ascii(data, at: 0, count: 8)
        guard id == magicStereoTOC || id == magicMultiTOC else { throw SACDISOError.invalidFormat }

        let sampleFrequencyCode = try byte(data, at: 20)
        let frameFormatCode = try byte(data, at: 21) & 0x0F
        let channelCount = Int(try byte(data, at: 32))
        let trackCount = Int(try byte(data, at: 69))
        let areaTrackStart = try uint32BE(data, at: 72)
        let areaTrackEnd = try uint32BE(data, at: 76)
        guard (1...6).contains(channelCount), (1...255).contains(trackCount) else {
            throw SACDISOError.invalidFormat
        }

        let sampleRate: Int
        switch sampleFrequencyCode {
        case 0x04: sampleRate = dsd64SampleRate
        default: throw SACDISOError.unsupportedFrameFormat
        }
        let frameFormat: SACDFrameFormat
        switch frameFormatCode {
        case 0: frameFormat = .dst
        case 2: frameFormat = .dsd3In14
        case 3: frameFormat = .dsd3In16
        default: throw SACDISOError.unsupportedFrameFormat
        }

        let starts = findTrackStarts(in: data, trackCount: trackCount)
        let times = findTrackTimes(in: data, trackCount: trackCount)
        let texts = findTrackTexts(in: data, trackCount: trackCount)
        var tracks: [SACDTrack] = []
        tracks.reserveCapacity(trackCount)
        for index in 0..<trackCount {
            let number = index + 1
            let startLSN: UInt32
            let lengthLSN: UInt32
            if let starts {
                startLSN = starts.starts[index]
                lengthLSN = max(1, starts.lengths[index])
            } else if areaTrackEnd >= areaTrackStart {
                let span = areaTrackEnd - areaTrackStart + 1
                let perTrack = max(1, span / UInt32(trackCount))
                startLSN = areaTrackStart + UInt32(index) * perTrack
                lengthLSN = index == trackCount - 1
                    ? areaTrackEnd - startLSN + 1
                    : perTrack
            } else {
                throw SACDISOError.invalidFormat
            }
            let startCue = times?.starts[index] ?? 0
            let durationCue: Int64
            if let times, times.durations[index] > 0 {
                durationCue = times.durations[index]
            } else if let times, index + 1 < trackCount {
                durationCue = max(0, times.starts[index + 1] - startCue)
            } else {
                durationCue = 0
            }
            let text = texts?[index]
            let artist = text?.artist ?? albumArtist
            tracks.append(
                SACDTrack(
                    number: number,
                    title: text?.title,
                    artist: artist,
                    composer: text?.composer,
                    startCueFrames: startCue,
                    durationCueFrames: durationCue,
                    startLSN: startLSN,
                    lengthLSN: lengthLSN
                )
            )
        }
        guard tracks.contains(where: { $0.durationCueFrames > 0 && $0.lengthLSN > 0 }) else {
            throw SACDISOError.invalidFormat
        }
        return SACDArea(
            id: id,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameFormat: frameFormat,
            tracks: tracks
        )
    }

    private static func parseMasterText(_ masterTOC: Data) -> (title: String?, artist: String?) {
        let textOffset = sectorSize
        guard masterTOC.count >= textOffset + 20,
              ascii(masterTOC, at: textOffset, count: 8) == magicMasterText else {
            return (nil, nil)
        }
        let titlePosition = (try? uint16BE(masterTOC, at: textOffset + 16)).map(Int.init) ?? 0
        let artistPosition = (try? uint16BE(masterTOC, at: textOffset + 18)).map(Int.init) ?? 0
        return (
            decodeCString(masterTOC, at: textOffset + titlePosition)?.text,
            decodeCString(masterTOC, at: textOffset + artistPosition)?.text
        )
    }

    private static func findTrackStarts(in data: Data, trackCount: Int) -> (starts: [UInt32], lengths: [UInt32])? {
        guard let offset = findMagic(magicTrackListOffset, in: data) else { return nil }
        var starts: [UInt32] = []
        var lengths: [UInt32] = []
        let startTable = offset + 8
        let lengthTable = startTable + 255 * 4
        for index in 0..<trackCount {
            guard let start = try? uint32BE(data, at: startTable + index * 4),
                  let length = try? uint32BE(data, at: lengthTable + index * 4) else {
                return nil
            }
            starts.append(start)
            lengths.append(length)
        }
        return (starts, lengths)
    }

    private static func findTrackTimes(in data: Data, trackCount: Int) -> (starts: [Int64], durations: [Int64])? {
        guard let offset = findMagic(magicTrackListTime, in: data) else { return nil }
        var starts: [Int64] = []
        var durations: [Int64] = []
        let startTable = offset + 8
        let durationTable = startTable + 255 * 4
        for index in 0..<trackCount {
            guard let start = try? timecode(data, at: startTable + index * 4),
                  let duration = try? timecode(data, at: durationTable + index * 4) else {
                return nil
            }
            starts.append(start)
            durations.append(duration)
        }
        return (starts, durations)
    }

    private static func findTrackTexts(in data: Data, trackCount: Int) -> [(title: String?, artist: String?, composer: String?)]? {
        guard let offset = findMagic(magicTrackText, in: data) else { return nil }
        var starts: [Int?] = []
        starts.reserveCapacity(trackCount)
        for index in 0..<trackCount {
            let positionOffset = offset + 8 + index * 2
            guard let relative = try? uint16BE(data, at: positionOffset), relative > 0 else {
                starts.append(nil)
                continue
            }
            starts.append(offset + Int(relative))
        }
        var result: [(title: String?, artist: String?, composer: String?)] = []
        result.reserveCapacity(trackCount)
        for index in 0..<trackCount {
            guard let start = starts[index], start < data.count else {
                result.append((nil, nil, nil))
                continue
            }
            let next = starts[(index + 1)...].compactMap { $0 }.first
            let end = min(next.map { $0 > start ? $0 : data.count } ?? data.count, data.count)
            result.append(parseTrackTextBlock(data, at: start, end: end))
        }
        return result
    }

    private static func parseTrackTextBlock(
        _ data: Data,
        at start: Int,
        end: Int
    ) -> (title: String?, artist: String?, composer: String?) {
        var title: String?
        var artist: String?
        var composer: String?
        var cursor = start
        // 实盘块首常见 `02 00 00 00`（条目数，小端）；夹具仍可能直接从 type 字节开始。
        if start + 4 <= end {
            let b0 = Int(data[start])
            let b1 = Int(data[start + 1])
            let b2 = Int(data[start + 2])
            let b3 = Int(data[start + 3])
            let littleEndianCount = (1...8).contains(b0) && b1 == 0 && b2 == 0 && b3 == 0
            let bigEndianCount = b0 == 0 && b1 == 0 && b2 == 0 && (1...8).contains(b3)
            if littleEndianCount || bigEndianCount {
                cursor += 4
            }
        }
        while cursor < end {
            while cursor < end, data[cursor] == 0 { cursor += 1 }
            guard cursor < end else { break }
            let type = Int(data[cursor])
            guard (1...8).contains(type) else { break }
            cursor += 1
            guard let parsed = decodeCString(data, at: cursor, end: end) else { break }
            cursor = parsed.next
            switch type {
            case 0x01 where title == nil: title = parsed.text
            case 0x02 where artist == nil: artist = parsed.text
            case 0x03 where composer == nil: composer = parsed.text
            case 0x04 where composer == nil: composer = parsed.text
            default: break
            }
        }
        return (title, artist, composer)
    }

    private static func findMagic(_ magic: String, in data: Data) -> Int? {
        let needle = Data(magic.utf8)
        guard needle.count == 8, data.count >= 8 else { return nil }
        var index = 0
        while index <= data.count - 8 {
            if data[index..<(index + 8)] == needle { return index }
            index += 1
        }
        return nil
    }

    private static func readSectors(_ handle: FileHandle, start: UInt32, count: Int) throws -> Data {
        guard count > 0 else { throw SACDISOError.invalidFormat }
        let offset = UInt64(start) * UInt64(sectorSize)
        let byteCount = count * sectorSize
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
            throw SACDISOError.truncated
        }
        return data
    }

    private static func sectorRange(_ data: Data, start: UInt32, count: Int) throws -> Data {
        let offset = Int(start) * sectorSize
        let end = offset + count * sectorSize
        guard offset >= 0, end <= data.count else { throw SACDISOError.truncated }
        return Data(data[offset..<end])
    }

    private static func ascii(_ data: Data, at offset: Int, count: Int) -> String {
        guard offset >= 0, offset + count <= data.count else { return "" }
        return String(data: data[offset..<(offset + count)], encoding: .ascii) ?? ""
    }

    private static func byte(_ data: Data, at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < data.count else { throw SACDISOError.truncated }
        return data[offset]
    }

    private static func uint16BE(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw SACDISOError.truncated }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func uint32BE(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw SACDISOError.truncated }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func timecode(_ data: Data, at offset: Int) throws -> Int64 {
        let minutes = Int64(try byte(data, at: offset))
        let seconds = Int64(try byte(data, at: offset + 1))
        let frames = Int64(try byte(data, at: offset + 2))
        return (minutes * 60 + seconds) * Int64(frameRate) + frames
    }

    private static func decodeCString(_ data: Data, at offset: Int, end: Int? = nil) -> (text: String, next: Int)? {
        guard offset > 0, offset < data.count else { return nil }
        let limit = min(end ?? data.count, data.count)
        var byteEnd = offset
        while byteEnd < limit, data[byteEnd] != 0 { byteEnd += 1 }
        guard byteEnd > offset else { return nil }
        let slice = data[offset..<byteEnd]
        let text = String(data: slice, encoding: .isoLatin1)
            ?? String(data: slice, encoding: .ascii)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        let next = byteEnd < limit ? byteEnd + 1 : byteEnd
        return (trimmed, next)
    }
}
