import Foundation
import Testing
@testable import HiFiExtensionCore

@Suite
struct SACDISOParserTests {
    @Test func sniffRejectsOrdinaryISOAndAcceptsMasterTOCMagic() throws {
        let ordinary = Data(repeating: 0, count: 511 * 2048)
        #expect(!SACDISOParser.sniff(ordinary))
        #expect(throws: DSDContainerError.unsupportedContainer) {
            try DSDContainerParser.parse(ordinary)
        }

        var marked = Data(repeating: 0, count: 511 * 2048)
        marked.replaceSubrange(
            (510 * 2048)..<(510 * 2048 + 8),
            with: Data("SACDMTOC".utf8)
        )
        #expect(SACDISOParser.sniff(marked))
    }

    @Test func parsesStereoTOCTitlesAndDurations() throws {
        let iso = try makeSACDISO(tracks: [
            TrackSpec(title: "Allegro", artist: "Beethoven", left: 0x11, right: 0x22),
            TrackSpec(title: "Andante", artist: "Beethoven", left: 0x33, right: 0x44)
        ])
        let disc = try SACDISOParser.parse(iso)
        #expect(disc.displayTitle == "Test Album")
        #expect(disc.albumArtist == "Test Artist")
        #expect(disc.year == "2020")
        let area = try #require(disc.stereoArea)
        #expect(area.channelCount == 2)
        #expect(area.sampleRate == 2_822_400)
        #expect(area.frameFormat == .dsd3In14)
        #expect(area.tracks.map(\.title) == ["Allegro", "Andante"])
        #expect(area.tracks.map(\.artist) == ["Beethoven", "Beethoven"])
        #expect(area.tracks.map(\.durationCueFrames) == [1, 1])
        #expect(area.tracks.map { $0.sampleCount(sampleRate: 2_822_400) } == [37_632, 37_632])

        let prefixed = try makeSACDISO(
            tracks: [
                TrackSpec(title: "Allegro", artist: "Beethoven", left: 0x11, right: 0x22),
                TrackSpec(title: "Andante", artist: "Beethoven", left: 0x33, right: 0x44)
            ],
            prefixedTrackText: true
        )
        let prefixedDisc = try SACDISOParser.parse(prefixed)
        #expect(prefixedDisc.stereoArea?.tracks.map(\.title) == ["Allegro", "Andante"])
        #expect(prefixedDisc.stereoArea?.tracks.map(\.artist) == ["Beethoven", "Beethoven"])

        let descriptor = try disc.containerDescriptor(trackNumber: 1)
        #expect(descriptor.kind == .sacd)
        #expect(descriptor.compression == .rawDSD)
        #expect(descriptor.channelCount == 2)
        #expect(descriptor.sampleCount == 37_632)
    }

    @Test func streamReadsInterleavedUncompressedFramesAndSeeks() throws {
        let iso = try makeSACDISO(tracks: [
            TrackSpec(title: "One", left: 0x11, right: 0x22),
            TrackSpec(title: "Two", left: 0x33, right: 0x44)
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-hifi-sacd-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try iso.write(to: url)

        #expect(SACDISOParser.sniff(fileAt: url))
        let disc = try SACDISOParser.parse(fileAt: url)
        let first = try SACDRawStream(fileAt: url, disc: disc, trackNumber: 1)
        #expect(first.format == DSDStreamFormat(
            sampleRate: 2_822_400,
            channelCount: 2,
            bitOrder: .mostSignificantBitFirst
        ))
        #expect(first.sampleCount == 37_632)
        let firstBytes = try first.read(maximumByteFrames: 4)
        #expect(firstBytes.bytesByChannel[0].prefix(4) == [0x11, 0x11, 0x11, 0x11])
        #expect(firstBytes.bytesByChannel[1].prefix(4) == [0x22, 0x22, 0x22, 0x22])
        try first.seek(toSample: 0)
        let all = try first.read(maximumByteFrames: 8_192)
        #expect(all.byteFrameCount == 4_704)
        #expect(all.bytesByChannel[0].allSatisfy { $0 == 0x11 })
        #expect(all.bytesByChannel[1].allSatisfy { $0 == 0x22 })
        #expect(try first.read(maximumByteFrames: 1).isEmpty)

        let second = try SACDRawStream(fileAt: url, disc: disc, trackNumber: 2)
        let secondBytes = try second.read(maximumByteFrames: 2)
        #expect(secondBytes.bytesByChannel == [[0x33, 0x33], [0x44, 0x44]])
        try second.seek(toSample: 16)
        #expect(try second.read(maximumByteFrames: 1).bytesByChannel == [[0x33], [0x44]])
        #expect(throws: DSDStreamError.seekMustBeByteAligned) {
            try second.seek(toSample: 1)
        }
    }

    @Test func rejectsDSTStereoAreaAndMissingTwoChannelTOC() throws {
        let dst = try makeSACDISO(
            tracks: [TrackSpec(title: "DST", left: 0x11, right: 0x22)],
            frameFormat: 0
        )
        let dstDisc = try SACDISOParser.parse(dst)
        #expect(dstDisc.stereoArea?.frameFormat == .dst)
        #expect(throws: SACDISOError.unsupportedFrameFormat) {
            _ = try dstDisc.containerDescriptor()
        }

        let multiOnly = try makeSACDISO(
            tracks: [TrackSpec(title: "Surround", left: 0x11, right: 0x22)],
            stereo: false
        )
        #expect(throws: SACDISOError.missingStereoArea) {
            _ = try SACDISOParser.parse(multiOnly)
        }
    }

    @Test func uncompressedSectorDoesNotConsumeDSTFrameInfoTable() throws {
        let audio = Data(repeating: 0xA5, count: 2016)
        let sector = try SACDAudioSector.encode(
            packets: [
                SACDAudioSector.Packet(startsFrame: false, dataType: 3, payload: Data(repeating: 0, count: 24)),
                SACDAudioSector.Packet(startsFrame: true, dataType: 2, payload: audio)
            ],
            frames: [SACDAudioSector.FrameInfo(minutes: 0, seconds: 0, frames: 0)]
        )
        #expect(sector.count == 2048)
        let decoded = try SACDAudioSector.decode(sector)
        #expect(!decoded.dstEncoded)
        #expect(decoded.packets.count == 2)
        #expect(decoded.packets[0].dataType == 3)
        #expect(decoded.packets[1].dataType == 2)
        #expect(decoded.packets[1].startsFrame)
        #expect(decoded.packets[1].payload == audio)
        #expect(decoded.remainder.count == 3)
    }

    @Test func dsdPayloadsStripZeroMarkerAndKeepThreeByteRemainder() {
        let marker = Data([0, 0, 0])
        let body = Data([0xAB, 0x65, 0x26, 0x4D])
        let remainder = Data([0x93, 0xAC, 0x55])
        let payloads = SACDAudioSector.dsdPayloads(
            packets: [
                SACDAudioSector.Packet(startsFrame: false, dataType: 3, payload: Data(repeating: 0, count: 24)),
                SACDAudioSector.Packet(startsFrame: true, dataType: 2, payload: marker + body)
            ],
            remainder: remainder
        )
        #expect(payloads.count == 2)
        #expect(payloads[0].startsFrame)
        #expect(payloads[0].payload == body)
        #expect(!payloads[1].startsFrame)
        #expect(payloads[1].payload == remainder)
        #expect(
            SACDAudioSector.dsdPayloads(
                packets: [SACDAudioSector.Packet(startsFrame: true, dataType: 2, payload: body)],
                remainder: Data(repeating: 0, count: 817)
            ).map { $0.payload } == [body]
        )
        #expect(
            SACDAudioSector.dsdPayloads(
                packets: [SACDAudioSector.Packet(startsFrame: true, dataType: 2, payload: marker + body)],
                remainder: Data()
            ).map { $0.payload } == [marker + body]
        )
    }

    @Test func streamKeepsTheNextFrameWhenItStartsInTheSameSector() throws {
        let iso = try makeSACDISO(tracks: [
            TrackSpec(title: "TwoFrames", left: 0x11, right: 0x22, frameCount: 2)
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-hifi-sacd-split-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try iso.write(to: url)

        let disc = try SACDISOParser.parse(fileAt: url)
        let stream = try SACDRawStream(fileAt: url, disc: disc, trackNumber: 1)
        #expect(stream.sampleCount == 37_632 * 2)
        let all = try stream.read(maximumByteFrames: 16_384)
        #expect(all.byteFrameCount == 9_408)
        #expect(all.bytesByChannel[0].allSatisfy { $0 == 0x11 })
        #expect(all.bytesByChannel[1].allSatisfy { $0 == 0x22 })
        #expect(try stream.read(maximumByteFrames: 1).isEmpty)
    }

    @Test func readsLocalUncompressedStereoISOWhenPresent() throws {
        let url = URL(
            fileURLWithPath: "/Users/dongchao/Music/无损/DSD/Beethoven Symphonies Nos.1-9 (5SACD) - Gunter Wand/Symphonies Nos.2 & 6.iso"
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let disc = try SACDISOParser.parse(fileAt: url)
        #expect(disc.stereoArea?.frameFormat == .dsd3In14)
        #expect((disc.stereoArea?.tracks.count ?? 0) >= 2)
        #expect(disc.stereoArea?.tracks.first?.title?.contains("Sinfonie Nr.2") == true)
        #expect(disc.stereoArea?.tracks.first?.artist?.contains("Gunter Wand") == true)
        let stream = try SACDRawStream(fileAt: url, disc: disc, trackNumber: 1)
        let chunk = try stream.read(maximumByteFrames: 32)
        #expect(chunk.bytesByChannel.count == 2)
        #expect(chunk.byteFrameCount == 32)
        #expect(Array(chunk.bytesByChannel[0].prefix(4)) == [0xAB, 0x26, 0xAC, 0xAA])
        #expect(Array(chunk.bytesByChannel[1].prefix(4)) == [0x65, 0x4D, 0x55, 0x93])
        let dsfURL = URL(
            fileURLWithPath: "/Users/dongchao/Music/无损/DSD/Beethoven_9 Sinfonien   Gunter Wand_NDR-Sinfonieorchester/Disc 2/01 - Sinfonie Nr.2  I. Adagio molto; Allegro con brio.dsf"
        )
        if FileManager.default.fileExists(atPath: dsfURL.path) {
            try stream.seek(toSample: 0)
            let dsf = try DSFRawStream(fileAt: dsfURL)
            let isoBytes = try stream.read(maximumByteFrames: 16_384)
            let dsfBytes = try dsf.read(maximumByteFrames: 16_384)
            #expect(isoBytes.byteFrameCount == 16_384)
            #expect(isoBytes.bytesByChannel == dsfBytes.bytesByChannel)
        }
        try stream.seek(toSample: 37632)
        let next = try stream.read(maximumByteFrames: 8)
        #expect(next.byteFrameCount == 8)
        try stream.seek(toSample: 2_822_400)
        let later = try stream.read(maximumByteFrames: 16)
        #expect(later.byteFrameCount == 16)
        #expect(stream.samplePosition >= 2_822_400)
    }

    @Test func mapsNewSACDErrorsToStableKeys() {
        #expect(HiFiPlaybackError.from(SACDISOError.invalidFormat) == .invalidSACDISO)
        #expect(HiFiPlaybackError.from(SACDISOError.missingStereoArea) == .unsupportedArea)
        #expect(HiFiPlaybackError.from(SACDISOError.unsupportedFrameFormat) == .unsupportedSource)
        #expect(HiFiPlaybackError.invalidSACDISO.localizationKey == "Hi-Fi Invalid SACD ISO")
        #expect(HiFiPlaybackError.unsupportedArea.localizationKey == "Hi-Fi Unsupported SACD Area")
    }

    private struct TrackSpec {
        var title: String
        var artist: String? = nil
        var left: UInt8
        var right: UInt8
        var frameCount: Int = 1
    }

    private func makeSACDISO(
        tracks: [TrackSpec],
        frameFormat: UInt8 = 2,
        stereo: Bool = true,
        prefixedTrackText: Bool = false
    ) throws -> Data {
        let sector = SACDISOParser.sectorSize
        let audioStart: UInt32 = 600
        var audioSectors: [Data] = []
        var trackStarts: [UInt32] = []
        var trackLengths: [UInt32] = []
        var cue: Int64 = 0
        for track in tracks {
            var interleaved = Data()
            interleaved.reserveCapacity(SACDAudioSector.dsd64BytesPerChannelPerFrame * 2 * track.frameCount)
            for _ in 0..<(SACDAudioSector.dsd64BytesPerChannelPerFrame * track.frameCount) {
                interleaved.append(track.left)
                interleaved.append(track.right)
            }
            let packed = try SACDAudioSector.packFrames(
                interleavedDSD: interleaved,
                channelCount: 2,
                startCueFrames: cue
            )
            trackStarts.append(audioStart + UInt32(audioSectors.count))
            trackLengths.append(UInt32(packed.count))
            audioSectors.append(contentsOf: packed)
            cue += 1
        }
        let audioEnd = audioStart + UInt32(audioSectors.count) - 1
        let totalSectors = Int(audioEnd) + 1
        var iso = Data(repeating: 0, count: totalSectors * sector)

        func write(_ payload: Data, lsn: UInt32) {
            let offset = Int(lsn) * sector
            iso.replaceSubrange(offset..<(offset + payload.count), with: payload)
        }

        var master = Data(repeating: 0, count: sector)
        master.replaceSubrange(0..<8, with: Data("SACDMTOC".utf8))
        master[8] = 1
        master[9] = 20
        writeUInt16BE(&master, 1, at: 16)
        writeUInt16BE(&master, 1, at: 18)
        if stereo {
            writeUInt32BE(&master, 544, at: 64)
            writeUInt16BE(&master, 10, at: 84)
        }
        writeUInt16BE(&master, 2020, at: 120)
        master[128] = 1
        write(master, lsn: 510)

        var text = Data(repeating: 0, count: sector)
        text.replaceSubrange(0..<8, with: Data("SACDText".utf8))
        writeUInt16BE(&text, 80, at: 16)
        writeUInt16BE(&text, 120, at: 18)
        text.replaceSubrange(80..<(80 + 11), with: Data("Test Album\0".utf8))
        text.replaceSubrange(120..<(120 + 12), with: Data("Test Artist\0".utf8))
        write(text, lsn: 511)

        var area = Data(repeating: 0, count: sector)
        area.replaceSubrange(0..<8, with: Data((stereo ? "TWOCHTOC" : "MULCHTOC").utf8))
        area[8] = 1
        area[9] = 20
        writeUInt16BE(&area, 10, at: 10)
        area[20] = 0x04
        area[21] = frameFormat
        area[32] = stereo ? 2 : 5
        area[69] = UInt8(tracks.count)
        writeUInt32BE(&area, audioStart, at: 72)
        writeUInt32BE(&area, audioEnd, at: 76)
        writeUInt16BE(&area, 3 * UInt16(sector), at: 128)
        write(area, lsn: 544)

        var trl1 = Data(repeating: 0, count: sector)
        trl1.replaceSubrange(0..<8, with: Data("SACDTRL1".utf8))
        for (index, start) in trackStarts.enumerated() {
            writeUInt32BE(&trl1, start, at: 8 + index * 4)
            writeUInt32BE(&trl1, trackLengths[index], at: 8 + 255 * 4 + index * 4)
        }
        write(trl1, lsn: 545)

        var trl2 = Data(repeating: 0, count: sector)
        trl2.replaceSubrange(0..<8, with: Data("SACDTRL2".utf8))
        var startCue = 0
        for (index, track) in tracks.enumerated() {
            writeTimecode(
                &trl2,
                minutes: 0,
                seconds: 0,
                frames: UInt8(startCue),
                at: 8 + index * 4
            )
            writeTimecode(
                &trl2,
                minutes: 0,
                seconds: 0,
                frames: UInt8(track.frameCount),
                at: 8 + 255 * 4 + index * 4
            )
            startCue += track.frameCount
        }
        write(trl2, lsn: 546)

        var trackText = Data(repeating: 0, count: sector)
        trackText.replaceSubrange(0..<8, with: Data("SACDTTxt".utf8))
        var cursor = 8 + tracks.count * 2
        for (index, track) in tracks.enumerated() {
            writeUInt16BE(&trackText, UInt16(cursor), at: 8 + index * 2)
            if prefixedTrackText {
                trackText[cursor] = UInt8(1 + (track.artist == nil ? 0 : 1))
                cursor += 4
            }
            trackText[cursor] = 0x01
            cursor += 1
            let title = Array((track.title + "\0").utf8)
            trackText.replaceSubrange(cursor..<(cursor + title.count), with: title)
            cursor += title.count
            if let artist = track.artist {
                trackText[cursor] = 0x02
                cursor += 1
                let name = Array((artist + "\0").utf8)
                trackText.replaceSubrange(cursor..<(cursor + name.count), with: name)
                cursor += name.count
            }
            trackText[cursor] = 0
            cursor += 1
        }
        write(trackText, lsn: 547)

        for (index, packed) in audioSectors.enumerated() {
            write(packed, lsn: audioStart + UInt32(index))
        }
        return iso
    }

    private func writeUInt16BE(_ data: inout Data, _ value: UInt16, at offset: Int) {
        data[offset] = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeUInt32BE(_ data: inout Data, _ value: UInt32, at offset: Int) {
        data[offset] = UInt8(value >> 24)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private func writeTimecode(
        _ data: inout Data,
        minutes: UInt8,
        seconds: UInt8,
        frames: UInt8,
        at offset: Int
    ) {
        data[offset] = minutes
        data[offset + 1] = seconds
        data[offset + 2] = frames
        data[offset + 3] = 0
    }
}
