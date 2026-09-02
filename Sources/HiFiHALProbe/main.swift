import Foundation
import HiFiExtensionCore

private struct ProbeOutput: Encodable {
    let mode: String
    let plan: DoPTransportPlan
    let result: HALFormatProbeResult?
    let silenceResult: HALDoPSilenceProbeResult?
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let deviceIndex = arguments.firstIndex(of: "--device"), deviceIndex + 1 < arguments.count,
      let rateIndex = arguments.firstIndex(of: "--dsd-rate"), rateIndex + 1 < arguments.count,
      let dsdRate = Int(arguments[rateIndex + 1]) else {
    FileHandle.standardError.write(Data(
        "Usage: hifi-hal-probe --device <AudioDeviceUID> --dsd-rate <2822400|5644800|11289600> [--apply | --dop-silence <seconds>]\n".utf8
    ))
    exit(64)
}

do {
    let plan = try CoreAudioHALFormatProbe.plan(
        deviceUID: arguments[deviceIndex + 1],
        dsdSampleRate: dsdRate
    )
    let silenceDuration: TimeInterval? = arguments.firstIndex(of: "--dop-silence").flatMap { index in
        guard index + 1 < arguments.count else { return nil }
        return TimeInterval(arguments[index + 1])
    }
    let applies = arguments.contains("--apply")
    guard !(applies && silenceDuration != nil) else {
        FileHandle.standardError.write(Data("Choose either --apply or --dop-silence.\n".utf8))
        exit(64)
    }
    let output = ProbeOutput(
        mode: silenceDuration != nil ? "dop-silence-and-restore" : (applies ? "apply-and-restore" : "dry-run"),
        plan: plan,
        result: applies ? try CoreAudioHALFormatProbe.applyAndRestore(plan) : nil,
        silenceResult: try silenceDuration.map {
            try CoreAudioHALFormatProbe.outputDoPSilenceAndRestore(plan, duration: $0)
        }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(output))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("HAL probe failed: \(error)\n".utf8))
    exit(1)
}
