import Foundation
import Testing
@testable import HiFiExtensionCore

@Suite
struct DSDContainerParserTests {
    @Test func parsesDSFFormatAndAudioChunk() throws {
        let data = makeDSF(sampleRate: 2_822_400, channels: 2, sampleCount: 5_644_800)
        let descriptor = try DSDContainerParser.parse(data)

        #expect(descriptor.kind == .dsf)
        #expect(descriptor.compression == .rawDSD)
        #expect(descriptor.sampleRate == 2_822_400)
        #expect(descriptor.channelCount == 2)
        #expect(descriptor.sampleCount == 5_644_800)
        #expect(descriptor.blockSizePerChannel == 4_096)
        #expect(descriptor.bitOrder == .leastSignificantBitFirst)
        #expect(descriptor.audioDataByteCount == 16)
        #expect(descriptor.duration == 2)
    }

    @Test func parsesMappedDSFFileWithoutChangingItsContents() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-hifi-parser-\(UUID().uuidString).dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = makeDSF(sampleRate: 5_644_800, channels: 2, sampleCount: 11_289_600)
        try data.write(to: url, options: .atomic)

        let descriptor = try DSDContainerParser.parse(fileAt: url)

        #expect(descriptor.sampleRate == 5_644_800)
        #expect(descriptor.duration == 2)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func stopsDSFChunkScanningAtTrailingID3Metadata() throws {
        let metadata = Data("ID3\u{4}\0\0\0\0\0\0metadata".utf8)
        let data = makeDSF(
            sampleRate: 2_822_400,
            channels: 2,
            sampleCount: 5_644_800,
            trailingMetadata: metadata
        )

        let descriptor = try DSDContainerParser.parse(data)

        #expect(descriptor.metadataOffset == UInt64(data.count - metadata.count))
        #expect(descriptor.audioDataByteCount == 16)
    }

    @Test func parsesRawAndDSTCompressedDFF() throws {
        let raw = try DSDContainerParser.parse(makeDFF(compression: "DSD ", audioChunk: "DSD "))
        #expect(raw.kind == .dff)
        #expect(raw.compression == .rawDSD)
        #expect(raw.sampleRate == 2_822_400)
        #expect(raw.channelCount == 2)
        #expect(raw.sampleCount == 64)
        #expect(raw.bitOrder == .mostSignificantBitFirst)

        let dst = try DSDContainerParser.parse(makeDFF(compression: "DST ", audioChunk: "DST "))
        #expect(dst.compression == .dst)
        #expect(dst.sampleCount == nil)
        #expect(dst.audioDataByteCount == 16)
    }

    @Test func rejectsTruncatedAndUnknownContainers() {
        #expect(throws: DSDContainerError.unsupportedContainer) {
            try DSDContainerParser.parse(Data("not audio".utf8))
        }
        let truncated = makeDSF(sampleRate: 2_822_400, channels: 2, sampleCount: 5_644_800).dropLast()
        #expect(throws: DSDContainerError.invalidFormat) {
            try DSDContainerParser.parse(Data(truncated))
        }
    }

    @Test func coreAudioCatalogUsesUniqueStableDeviceIdentifiers() throws {
        let devices = try CoreAudioDeviceCatalog.outputDevices()
        #expect(Set(devices.map(\.id)).count == devices.count)
        #expect(devices.allSatisfy { !$0.id.isEmpty && !$0.displayName.isEmpty })
        #expect(devices.filter(\.isSystemDefault).count <= 1)
        #expect(devices.allSatisfy {
            Set($0.potentialDoPDSDRates).isSubset(of: [2_822_400, 5_644_800, 11_289_600])
        })
    }

    @Test func infersOnlyIntegerPCMDoPCarrierCandidates() {
        let formats = [
            physicalFormat(rate: 176_400, bits: 24),
            physicalFormat(rate: 352_800, bits: 32),
            physicalFormat(rate: 705_600, bits: 32, isFloat: true),
            physicalFormat(rate: 176_400, bits: 16)
        ]

        #expect(CoreAudioDeviceCatalog.potentialDoPDSDRates(from: formats) == [2_822_400, 5_644_800])
    }

    @Test func doPEncoderAlternatesMarkersAcrossChunks() throws {
        var encoder = DoPFrameEncoder()
        let first = try encoder.encode(dsdBytesByChannel: [
            [0x11, 0x22, 0x33, 0x44],
            [0x55, 0x66, 0x77, 0x88]
        ])
        let second = try encoder.encode(dsdBytesByChannel: [[0x99, 0xAA], [0xBB, 0xCC]])

        #expect(first == [0x0005_1122, 0x0005_5566, 0x00FA_3344, 0x00FA_7788])
        #expect(second == [0x0005_99AA, 0x0005_BBCC])
    }

    @Test func doPEncoderRejectsIncompleteOrUnbalancedChannels() {
        var encoder = DoPFrameEncoder()
        #expect(throws: DoPFrameEncoderError.mismatchedChannelLengths) {
            try encoder.encode(dsdBytesByChannel: [[0x00, 0x01], [0x00]])
        }
        #expect(throws: DoPFrameEncoderError.incompleteDSDFrame) {
            try encoder.encode(dsdBytesByChannel: [[0x00]])
        }
    }

    @Test func doPEncoderPacksAlignedHighLittleEndianContainers() {
        let format = physicalFormat(rate: 176_400, bits: 24, isAlignedHigh: true)
        #expect(DoPFrameEncoder.pack(0x0005_1122, for: format) == 0x0511_2200)
    }

    @Test func doPEncoderUsesHigh24BitsIn32BitPackedCoreAudioContainers() {
        let format = physicalFormat(rate: 176_400, bits: 32)
        #expect(DoPFrameEncoder.pack(0x0005_1122, for: format) == 0x0511_2200)
    }

    @Test func doPPhysicalWordsRoundTripExactlyThroughFloat32VirtualSamples() {
        let format = physicalFormat(rate: 176_400, bits: 32)
        for word in [UInt32(0x0005_6969), UInt32(0x00FA_6969)] {
            let packed = DoPFrameEncoder.pack(word, for: format)
            let sample = DoPFrameEncoder.float32Sample(forPackedPhysicalWord: packed)
            let reconstructed = UInt32(bitPattern: Int32(sample * 2_147_483_648))
            #expect(reconstructed == packed)
        }
    }

    @Test func dsfStreamReadsChannelBlocksNormalizesBitsAndSeeks() throws {
        let audio: [UInt8] = [
            0x01, 0x02, 0x04, 0x08,
            0x10, 0x20, 0x40, 0x80,
            0x03, 0x0C, 0x00, 0x00,
            0xC0, 0x30, 0x00, 0x00
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-hifi-stream-\(UUID().uuidString).dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeDSF(
            sampleRate: 2_822_400,
            channels: 2,
            sampleCount: 48,
            blockSize: 4,
            audioPayload: Data(audio)
        ).write(to: url)

        let stream = try DSFRawStream(fileAt: url)
        #expect(stream.format == DSDStreamFormat(
            sampleRate: 2_822_400,
            channelCount: 2,
            bitOrder: .mostSignificantBitFirst
        ))
        #expect(try stream.read(maximumByteFrames: 3).bytesByChannel == [
            [0x80, 0x40, 0x20],
            [0x08, 0x04, 0x02]
        ])
        #expect(try stream.read(maximumByteFrames: 3).bytesByChannel == [
            [0x10, 0xC0, 0x30],
            [0x01, 0x03, 0x0C]
        ])
        #expect(stream.samplePosition == 48)
        #expect(try stream.read(maximumByteFrames: 1).isEmpty)

        try stream.seek(toSample: 32)
        #expect(try stream.read(maximumByteFrames: 8).bytesByChannel == [
            [0xC0, 0x30],
            [0x03, 0x0C]
        ])
        #expect(throws: DSDStreamError.seekMustBeByteAligned) {
            try stream.seek(toSample: 1)
        }
    }

    @Test func spscRingBufferPreservesInterleavedFramesAcrossWraparound() {
        let ring = SPSCFloatRingBuffer(capacityFrames: 3, channelCount: 2)
        let first: [Float32] = [1, 2, 3, 4, 5, 6]
        #expect(first.withUnsafeBufferPointer { ring.write(interleavedSamples: $0) } == 3)
        var output = [Float32](repeating: 0, count: 4)
        #expect(output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maximumFrames: 2)
        } == 2)
        #expect(output == [1, 2, 3, 4])

        let second: [Float32] = [7, 8, 9, 10]
        #expect(second.withUnsafeBufferPointer { ring.write(interleavedSamples: $0) } == 2)
        output = [Float32](repeating: 0, count: 6)
        #expect(output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maximumFrames: 3)
        } == 3)
        #expect(output == [5, 6, 7, 8, 9, 10])
        #expect(ring.availableFrames == 0)
    }

    @Test func dsfDoPSourceProducesFloatFramesThatRecoverPhysicalWords() throws {
        let audio = Data([
            0x88, 0x44, 0xCC, 0x22,
            0xAA, 0x66, 0xEE, 0x11
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-hifi-dop-source-\(UUID().uuidString).dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeDSF(
            sampleRate: 2_822_400,
            channels: 2,
            sampleCount: 32,
            blockSize: 4,
            audioPayload: audio
        ).write(to: url)

        let source = try DSFDoPSource(
            fileAt: url,
            physicalFormat: physicalFormat(rate: 176_400, bits: 32)
        )
        let samples = try source.read(maximumDoPFrames: 2)
        let recovered = samples.map { UInt32(bitPattern: Int32($0 * 2_147_483_648)) }
        #expect(recovered == [0x0511_2200, 0x0555_6600, 0xFA33_4400, 0xFA77_8800])
        #expect(try source.read(maximumDoPFrames: 1).isEmpty)
    }

    private func makeDSF(
        sampleRate: UInt32,
        channels: UInt32,
        sampleCount: UInt64,
        blockSize: UInt32 = 4_096,
        audioPayload: Data = Data(repeating: 0x69, count: 16),
        trailingMetadata: Data = Data()
    ) -> Data {
        var formatPayload = Data()
        formatPayload.appendLE(UInt32(1))
        formatPayload.appendLE(UInt32(0))
        formatPayload.appendLE(UInt32(2))
        formatPayload.appendLE(channels)
        formatPayload.appendLE(sampleRate)
        formatPayload.appendLE(UInt32(1))
        formatPayload.appendLE(sampleCount)
        formatPayload.appendLE(blockSize)
        formatPayload.appendLE(UInt32(0))
        let format = littleEndianChunk("fmt ", payload: formatPayload)
        let audio = littleEndianChunk("data", payload: audioPayload)
        let metadataOffset = UInt64(28 + format.count + audio.count)
        let fileSize = metadataOffset + UInt64(trailingMetadata.count)

        var data = Data("DSD ".utf8)
        data.appendLE(UInt64(28))
        data.appendLE(fileSize)
        data.appendLE(trailingMetadata.isEmpty ? UInt64(0) : metadataOffset)
        data.append(format)
        data.append(audio)
        data.append(trailingMetadata)
        return data
    }

    private func makeDFF(compression: String, audioChunk: String) -> Data {
        var soundProperties = Data("SND ".utf8)
        var sampleRate = Data()
        sampleRate.appendBE(UInt32(2_822_400))
        soundProperties.append(bigEndianChunk("FS  ", payload: sampleRate))
        var channels = Data()
        channels.appendBE(UInt16(2))
        channels.append(Data("SLFTSRGT".utf8))
        soundProperties.append(bigEndianChunk("CHNL", payload: channels))
        soundProperties.append(bigEndianChunk("CMPR", payload: Data(compression.utf8)))

        var body = Data("DSD ".utf8)
        body.append(bigEndianChunk("PROP", payload: soundProperties))
        body.append(bigEndianChunk(audioChunk, payload: Data(repeating: 0x96, count: 16)))
        var data = Data("FRM8".utf8)
        data.appendBE(UInt64(body.count))
        data.append(body)
        return data
    }

    private func physicalFormat(
        rate: Double,
        bits: UInt32,
        isFloat: Bool = false,
        isAlignedHigh: Bool = false
    ) -> HiFiAudioPhysicalFormat {
        HiFiAudioPhysicalFormat(
            formatID: "lpcm",
            minimumSampleRate: rate,
            maximumSampleRate: rate,
            channelCount: 2,
            bitsPerChannel: bits,
            bytesPerFrame: bits <= 24 ? 6 : 8,
            formatFlags: 0,
            isLinearPCM: true,
            isFloat: isFloat,
            isSignedInteger: !isFloat,
            isBigEndian: false,
            isPacked: true,
            isAlignedHigh: isAlignedHigh,
            isNonMixable: true
        )
    }

    private func littleEndianChunk(_ identifier: String, payload: Data) -> Data {
        var data = Data(identifier.utf8)
        data.appendLE(UInt64(payload.count + 12))
        data.append(payload)
        return data
    }

    private func bigEndianChunk(_ identifier: String, payload: Data) -> Data {
        var data = Data(identifier.utf8)
        data.appendBE(UInt64(payload.count))
        data.append(payload)
        if payload.count % 2 == 1 { data.append(0) }
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
