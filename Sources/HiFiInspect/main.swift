import Foundation
import HiFiExtensionCore

private struct Inspection: Encodable {
    let file: String?
    let descriptor: DSDContainerDescriptor?
    let streamCheck: StreamCheck?
    let outputDevices: [HiFiAudioOutputDevice]
}

private struct StreamCheck: Encodable {
    let normalizedFormat: DSDStreamFormatOutput
    let firstByteFrameCount: Int
    let firstDoPWords: [UInt32]
    let tailStartSample: UInt64
    let tailByteFrameCount: Int
    let finalSamplePosition: UInt64
}

private struct DSDStreamFormatOutput: Encodable {
    let sampleRate: Int
    let channelCount: Int
    let bitOrder: DSDBitOrder
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments == ["--devices"] || arguments.count == 1
        || (arguments.count == 2 && arguments[0] == "--stream-check") else {
    FileHandle.standardError.write(Data(
        "Usage: hifi-inspect <file.dsf|file.dff|--devices> | hifi-inspect --stream-check <file.dsf>\n".utf8
    ))
    exit(64)
}

do {
    let devices = try CoreAudioDeviceCatalog.outputDevices()
    let inspection: Inspection
    if arguments == ["--devices"] {
        inspection = Inspection(file: nil, descriptor: nil, streamCheck: nil, outputDevices: devices)
    } else {
        let checksStream = arguments.first == "--stream-check"
        let url = URL(fileURLWithPath: arguments.last!).standardizedFileURL
        let descriptor = try DSDContainerParser.parse(fileAt: url)
        let streamCheck: StreamCheck?
        if checksStream {
            let stream = try DSFRawStream(fileAt: url)
            let first = try stream.read(maximumByteFrames: 16)
            var doPEncoder = DoPFrameEncoder()
            let doPByteFrameCount = first.byteFrameCount - first.byteFrameCount % 2
            let words = try doPEncoder.encode(dsdBytesByChannel: first.bytesByChannel.map {
                Array($0.prefix(doPByteFrameCount))
            })
            let validByteFrames = (stream.sampleCount + 7) / 8
            let tailStartByte = validByteFrames > 16 ? validByteFrames - 16 : 0
            let tailStartSample = tailStartByte * 8
            try stream.seek(toSample: tailStartSample)
            let tail = try stream.read(maximumByteFrames: 16)
            streamCheck = StreamCheck(
                normalizedFormat: DSDStreamFormatOutput(
                    sampleRate: stream.format.sampleRate,
                    channelCount: stream.format.channelCount,
                    bitOrder: stream.format.bitOrder
                ),
                firstByteFrameCount: first.byteFrameCount,
                firstDoPWords: Array(words.prefix(8)),
                tailStartSample: tailStartSample,
                tailByteFrameCount: tail.byteFrameCount,
                finalSamplePosition: stream.samplePosition
            )
        } else {
            streamCheck = nil
        }
        inspection = Inspection(
            file: url.path,
            descriptor: descriptor,
            streamCheck: streamCheck,
            outputDevices: devices
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(inspection))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Hi-Fi inspection failed: \(error)\n".utf8))
    exit(1)
}
