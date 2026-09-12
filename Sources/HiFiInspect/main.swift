import Foundation
import HiFiExtensionCore

private struct Inspection: Encodable {
    let file: String?
    let descriptor: DSDContainerDescriptor?
    let apeDescriptor: APEAudioDescriptor?
    let cueSheet: CUESheetOutput?
    let streamCheck: StreamCheck?
    let apeStreamCheck: APEStreamCheck?
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

private struct APEStreamCheck: Encodable {
    let normalizedFormat: APEStreamFormatOutput
    let firstFrameCount: Int
    let firstSamples: [Float32]
    let tailStartBlock: UInt64
    let tailFrameCount: Int
    let finalSamplePosition: UInt64
}

private struct APEStreamFormatOutput: Encodable {
    let sampleRate: Int
    let channelCount: Int
    let bitsPerSample: Int
    let isFloat: Bool
}

private struct CUESheetOutput: Encodable {
    let title: String
    let audioFile: String
    let tracks: [CUESheetTrackOutput]
}

private struct CUESheetTrackOutput: Encodable {
    let number: Int
    let title: String?
    let startBlock: UInt64
    let endBlock: UInt64?
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments == ["--devices"] || arguments.count == 1
        || (arguments.count == 2 && arguments[0] == "--stream-check") else {
    FileHandle.standardError.write(Data(
        "Usage: hifi-inspect <file.dsf|file.dff|file.iso|file.ape|file.cue|--devices> | hifi-inspect --stream-check <file>\n".utf8
    ))
    exit(64)
}

do {
    let devices = try CoreAudioDeviceCatalog.outputDevices()
    let inspection: Inspection
    if arguments == ["--devices"] {
        inspection = Inspection(
            file: nil, descriptor: nil, apeDescriptor: nil, cueSheet: nil,
            streamCheck: nil, apeStreamCheck: nil, outputDevices: devices
        )
    } else {
        let checksStream = arguments.first == "--stream-check"
        let url = URL(fileURLWithPath: arguments.last!).standardizedFileURL
        let ext = url.pathExtension.lowercased()
        if ext == "cue" {
            inspection = try inspectCUE(url: url, devices: devices)
        } else if ext == "ape" {
            inspection = try inspectAPE(url: url, checksStream: checksStream, devices: devices)
        } else {
            inspection = try inspectDSD(url: url, checksStream: checksStream, devices: devices)
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(inspection))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Hi-Fi inspection failed: \(error)\n".utf8))
    exit(1)
}

private func inspectDSD(url: URL, checksStream: Bool, devices: [HiFiAudioOutputDevice]) throws -> Inspection {
    let descriptor = try DSDContainerParser.parse(fileAt: url)
    let streamCheck: StreamCheck?
    if checksStream {
        let stream = try DSDStreamFactory.make(fileAt: url)
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
    return Inspection(
        file: url.path,
        descriptor: descriptor,
        apeDescriptor: nil,
        cueSheet: nil,
        streamCheck: streamCheck,
        apeStreamCheck: nil,
        outputDevices: devices
    )
}

private func inspectAPE(url: URL, checksStream: Bool, devices: [HiFiAudioOutputDevice]) throws -> Inspection {
    let descriptor = try APEParser.parse(fileAt: url)
    let apeStreamCheck: APEStreamCheck?
    if checksStream {
        let stream = try APERawStream(fileAt: url)
        let first = try stream.read(maximumFrames: 16)
        let validBlocks = stream.sampleCount
        let tailStartBlock = validBlocks > 16 ? validBlocks - 16 : 0
        try stream.seek(toSample: tailStartBlock)
        let tail = try stream.read(maximumFrames: 16)
        apeStreamCheck = APEStreamCheck(
            normalizedFormat: APEStreamFormatOutput(
                sampleRate: stream.format.sampleRate,
                channelCount: stream.format.channelCount,
                bitsPerSample: stream.format.bitsPerSample,
                isFloat: stream.format.isFloat
            ),
            firstFrameCount: first.count / stream.format.channelCount,
            firstSamples: Array(first.prefix(8)),
            tailStartBlock: tailStartBlock,
            tailFrameCount: tail.count / stream.format.channelCount,
            finalSamplePosition: stream.samplePosition
        )
    } else {
        apeStreamCheck = nil
    }
    return Inspection(
        file: url.path,
        descriptor: nil,
        apeDescriptor: descriptor,
        cueSheet: nil,
        streamCheck: nil,
        apeStreamCheck: apeStreamCheck,
        outputDevices: devices
    )
}

private func inspectCUE(url: URL, devices: [HiFiAudioOutputDevice]) throws -> Inspection {
    guard let data = try? Data(contentsOf: url),
          let text = APECueSheetParser.decodeText(data) else {
        throw APECueSheetError.unreadable
    }
    // 采样率未知时先按文件名配对找 APE 取真实采样率，否则按 44.1k 展示结构。
    let siblingRate = APECueSheetParser.resolveAudioURL(
        named: ((try? cueAudioFileName(text: text)) ?? ""),
        cueURL: url
    ).flatMap { try? APEParser.parse(fileAt: $0).sampleRate }
    let sheet = APECueSheetParser.parse(text: text, cueURL: url, sampleRate: siblingRate ?? 44100)
    let output = sheet.map {
        CUESheetOutput(
            title: $0.displayTitle,
            audioFile: $0.audioFileName,
            tracks: $0.tracks.map {
                CUESheetTrackOutput(
                    number: $0.number,
                    title: $0.title,
                    startBlock: $0.startBlock,
                    endBlock: $0.endBlock
                )
            }
        )
    }
    var apeDescriptor: APEAudioDescriptor?
    if let audioURL = sheet?.audioURL {
        apeDescriptor = try? APEParser.parse(fileAt: audioURL)
    }
    return Inspection(
        file: url.path,
        descriptor: nil,
        apeDescriptor: apeDescriptor,
        cueSheet: output,
        streamCheck: nil,
        apeStreamCheck: nil,
        outputDevices: devices
    )
}

private func cueAudioFileName(text: String) throws -> String {
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              let parsed = APECueSheetParser.parseLine(line),
              parsed.command == "FILE",
              let name = parsed.arguments.first else { continue }
        return name
    }
    throw APECueSheetError.notAPECue
}
