//
//  APEPlaybackTests.swift
//  HiFiExtensionCoreTests
//
//  Created by 董超 on 2026/9/12.
//

import Foundation
import Testing
@testable import HiFiExtensionCore

@Suite
struct APEPlaybackTests {
    @Test func parsesNewFormatFixtures() throws {
        for (name, level) in [("sine05-fast", 1000), ("sine05-high", 3000)] {
            let url = try fixtureURL(named: name, extension: "ape")
            #expect(APEParser.sniff(fileAt: url))
            let descriptor = try APEParser.parse(fileAt: url)
            #expect(descriptor.fileVersion == 3990)
            #expect(descriptor.compressionLevel == level)
            #expect(descriptor.sampleRate == 44100)
            #expect(descriptor.channelCount == 2)
            #expect(descriptor.bitsPerSample == 16)
            #expect(!descriptor.isFloat)
            #expect(descriptor.totalBlocks == 22050)
            #expect(descriptor.duration == 0.5)
        }
    }

    @Test func parsesOldHeaderLayout() throws {
        // 用户实盘 CDImage.ape 的头布局：3.97 High，16-bit 立体声 44.1k。
        var header = Data(count: 32)
        header[0] = UInt8(ascii: "M")
        header[1] = UInt8(ascii: "A")
        header[2] = UInt8(ascii: "C")
        header[3] = UInt8(ascii: " ")
        header.writeLE(UInt16(3970), at: 4)
        header.writeLE(UInt16(3000), at: 6)
        header.writeLE(UInt16(54), at: 8)
        header.writeLE(UInt16(2), at: 10)
        header.writeLE(UInt32(44100), at: 12)
        header.writeLE(UInt32(729), at: 24)
        header.writeLE(UInt32(101128), at: 28)

        let descriptor = try APEParser.parse(header)
        #expect(descriptor.fileVersion == 3970)
        #expect(descriptor.compressionLevel == 3000)
        #expect(descriptor.blocksPerFrame == 73728 * 4)
        #expect(descriptor.totalBlocks == 728 * 294912 + 101128)
        #expect(descriptor.sampleRate == 44100)
        #expect(descriptor.channelCount == 2)
        #expect(descriptor.bitsPerSample == 16)
    }

    @Test func rejectsNonAPEAndTruncatedData() {
        #expect(!APEParser.sniff(Data("not audio".utf8)))
        #expect(throws: APEParserError.notAPE) {
            try APEParser.parse(Data("not audio".utf8))
        }
        #expect(throws: APEParserError.truncated) {
            try APEParser.parse(Data("MAC ".utf8))
        }
        var badLevel = Data(count: 32)
        badLevel[0] = UInt8(ascii: "M")
        badLevel[1] = UInt8(ascii: "A")
        badLevel[2] = UInt8(ascii: "C")
        badLevel[3] = UInt8(ascii: " ")
        badLevel.writeLE(UInt16(3970), at: 4)
        badLevel.writeLE(UInt16(9999), at: 6)
        #expect(throws: APEParserError.unsupportedFormat("compression-level-9999")) {
            try APEParser.parse(badLevel)
        }
    }

    @Test func decodesFixturesBitExactly() throws {
        let wavPayload = try wavPayloadData()
        for name in ["sine05-fast", "sine05-high"] {
            let url = try fixtureURL(named: name, extension: "ape")
            let decoder = try APEFileDecoder(fileAt: url)
            #expect(decoder.descriptor.totalBlocks == 22050)
            var decoded = Data()
            while true {
                let chunk = try decoder.decode(maxBlocks: 4096)
                if chunk.isEmpty { break }
                decoded.append(chunk)
            }
            #expect(decoded == wavPayload)
        }
    }

    @Test func streamReadsFloatsSeeksAndBoundsCueRange() throws {
        let url = try fixtureURL(named: "sine05-high", extension: "ape")
        let expected = try expectedFloats()
        let stream = try APERawStream(fileAt: url)
        #expect(stream.format == PCMStreamFormat(
            sampleRate: 44100,
            channelCount: 2,
            bitsPerSample: 16,
            isFloat: false
        ))
        #expect(stream.sampleCount == 22050)
        var all: [Float32] = []
        while true {
            let chunk = try stream.read(maximumFrames: 4096)
            if chunk.isEmpty { break }
            all += chunk
        }
        #expect(all == expected)
        #expect(stream.samplePosition == 22050)

        try stream.seek(toSample: 11025)
        let tail = try stream.read(maximumFrames: 22050)
        #expect(Array(tail) == Array(expected.dropFirst(11025 * 2)))
        #expect(throws: APEStreamError.invalidSeekPosition) {
            try stream.seek(toSample: 22051)
        }

        // CUE 曲目是有界视图：只读自己区间，seek 相对区间起点。
        let ranged = try APERawStream(fileAt: url, startBlock: 1000, endBlock: 2000)
        #expect(ranged.sampleCount == 1000)
        let first = try ranged.read(maximumFrames: 1000)
        #expect(first == Array(expected.dropFirst(1000 * 2).prefix(1000 * 2)))
        try ranged.seek(toSample: 0)
        #expect(ranged.samplePosition == 0)
        #expect(throws: APEStreamError.invalidSeekPosition) {
            _ = try APERawStream(fileAt: url, startBlock: 2000, endBlock: 1000)
        }
    }

    @Test func cueSheetParsesSingleAPECue() throws {
        let text = """
        REM GENRE Classical
        PERFORMER "Mahler; Mehta"
        TITLE "Mahler Symphony No 2"
        FILE "CDImage.ape" WAVE
          TRACK 01 AUDIO
            TITLE "I. Allegro maestoso"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "II. Andante moderato"
            INDEX 01 21:03:00
          TRACK 03 AUDIO
            TITLE "III. Scherzo"
            INDEX 01 31:15:00
        """
        let cueURL = URL(fileURLWithPath: "/Music/CDImage.cue")
        let sheet = try #require(APECueSheetParser.parse(text: text, cueURL: cueURL, sampleRate: 44100))
        #expect(sheet.title == "Mahler Symphony No 2")
        #expect(sheet.audioFileName == "CDImage.ape")
        #expect(sheet.tracks.count == 3)
        #expect(sheet.tracks[0].startBlock == 0)
        #expect(sheet.tracks[0].endBlock == 94725 * 588)
        #expect(sheet.tracks[1].startBlock == 94725 * 588)
        #expect(sheet.tracks[1].title == "II. Andante moderato")
        #expect(sheet.tracks[2].startBlock == 140625 * 588)
        #expect(sheet.tracks[2].endBlock == nil)
    }

    @Test func cueSheetRejectsNonAPEOrMultiFile() {
        let wavCue = """
        FILE "CDImage.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        """
        #expect(APECueSheetParser.parse(
            text: wavCue,
            cueURL: URL(fileURLWithPath: "/Music/CDImage.cue"),
            sampleRate: 44100
        ) == nil)
        let multiCue = """
        FILE "A.ape" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        FILE "B.ape" WAVE
          TRACK 02 AUDIO
            INDEX 01 05:00:00
        """
        #expect(APECueSheetParser.parse(
            text: multiCue,
            cueURL: URL(fileURLWithPath: "/Music/CDImage.cue"),
            sampleRate: 44100
        ) == nil)
    }

    @Test func cueFramesToBlocksRoundsHalfUp() {
        #expect(APECueSheetParser.cueFramesToBlocks(75, sampleRate: 44100) == 44100)
        #expect(APECueSheetParser.cueFramesToBlocks(1, sampleRate: 44100) == 588)
        // 不可整除采样率四舍五入到最近块。
        #expect(APECueSheetParser.cueFramesToBlocks(1, sampleRate: 32000) == 427)
    }

    // MARK: - Helpers

    private func fixtureURL(named name: String, extension ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw APEParserError.notAPE
        }
        return url
    }

    private func wavPayloadData() throws -> Data {
        let url = try fixtureURL(named: "sine05", extension: "wav")
        let data = try Data(contentsOf: url)
        guard let range = data.range(of: Data("data".utf8)) else { throw APEParserError.invalidFormat }
        return Data(data.suffix(from: range.upperBound + 4))
    }

    private func expectedFloats() throws -> [Float32] {
        let payload = try wavPayloadData()
        let bytes = Array(payload)
        var output: [Float32] = []
        output.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let word = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            output.append(Float32(Int16(bitPattern: word)) / 32768)
        }
        return output
    }
}

private extension Data {
    mutating func writeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var value = value.littleEndian
        withUnsafeMutableBytes { raw in
            Swift.withUnsafeBytes(of: &value) { source in
                raw[offset..<(offset + MemoryLayout<T>.size)].copyBytes(from: source)
            }
        }
    }
}
