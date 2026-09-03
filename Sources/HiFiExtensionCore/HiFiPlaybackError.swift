import Foundation

/// 跨 Runtime JSON 边界的稳定失败码；宿主用 localizationKey 显示英文/简体中文。
public enum HiFiPlaybackError: Error, Equatable, Sendable {
    case invalidDSF
    case invalidSACDISO
    case unsupportedSource
    case unsupportedArea
    case deviceDisconnected
    case deviceBusy
    case unsupportedDoPRate
    case exclusiveModeFailure
    case outputInitializationFailure
    case resourceAuthorizationFailure
    case seekIndexFailure

    public var localizationKey: String {
        switch self {
        case .invalidDSF: "Hi-Fi Invalid DSF"
        case .invalidSACDISO: "Hi-Fi Invalid SACD ISO"
        case .unsupportedSource: "Hi-Fi Unsupported Source"
        case .unsupportedArea: "Hi-Fi Unsupported SACD Area"
        case .deviceDisconnected: "Hi-Fi Device Disconnected"
        case .deviceBusy: "Hi-Fi Device Busy"
        case .unsupportedDoPRate: "Hi-Fi Unsupported DoP Rate"
        case .exclusiveModeFailure: "Hi-Fi Exclusive Mode Failed"
        case .outputInitializationFailure: "Hi-Fi Output Initialization Failed"
        case .resourceAuthorizationFailure: "Hi-Fi Resource Access Failed"
        case .seekIndexFailure: "Hi-Fi Seek Failed"
        }
    }

    public init?(localizationKey: String) {
        switch localizationKey {
        case "Hi-Fi Invalid DSF": self = .invalidDSF
        case "Hi-Fi Invalid SACD ISO": self = .invalidSACDISO
        case "Hi-Fi Unsupported Source": self = .unsupportedSource
        case "Hi-Fi Unsupported SACD Area": self = .unsupportedArea
        case "Hi-Fi Device Disconnected": self = .deviceDisconnected
        case "Hi-Fi Device Busy": self = .deviceBusy
        case "Hi-Fi Unsupported DoP Rate": self = .unsupportedDoPRate
        case "Hi-Fi Exclusive Mode Failed": self = .exclusiveModeFailure
        case "Hi-Fi Output Initialization Failed": self = .outputInitializationFailure
        case "Hi-Fi Resource Access Failed": self = .resourceAuthorizationFailure
        case "Hi-Fi Seek Failed": self = .seekIndexFailure
        default: return nil
        }
    }

    public static func from(_ error: Error) -> HiFiPlaybackError {
        if let error = error as? HiFiPlaybackError { return error }
        if let error = error as? CoreAudioHALFormatProbeError { return from(error) }
        if let error = error as? HALDSFPlaybackError { return from(error) }
        if let error = error as? DSDContainerError { return from(error) }
        if let error = error as? DSDStreamError { return from(error) }
        if let error = error as? SACDISOError { return from(error) }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileReadNoSuchFileError, NSFileReadUnknownError]
            .contains(nsError.code) {
            return .resourceAuthorizationFailure
        }
        return .outputInitializationFailure
    }

    private static func from(_ error: CoreAudioHALFormatProbeError) -> HiFiPlaybackError {
        switch error {
        case .deviceNotFound: .deviceDisconnected
        case .deviceInUse: .deviceBusy
        case .hogModeAcquireFailed, .hogModeReleaseFailed: .exclusiveModeFailure
        case .unsupportedDSDRate, .noDoPTransport: .unsupportedDoPRate
        default: .outputInitializationFailure
        }
    }

    private static func from(_ error: HALDSFPlaybackError) -> HiFiPlaybackError {
        switch error {
        case .unsupportedSource: .unsupportedSource
        case .invalidStartPosition: .seekIndexFailure
        case .outputBufferLayout: .outputInitializationFailure
        }
    }

    private static func from(_ error: DSDContainerError) -> HiFiPlaybackError {
        switch error {
        case .unsupportedCompression: .unsupportedSource
        default: .invalidDSF
        }
    }

    private static func from(_ error: DSDStreamError) -> HiFiPlaybackError {
        switch error {
        case .unsupportedFormat: .unsupportedSource
        case .invalidSeekPosition, .seekMustBeByteAligned: .seekIndexFailure
        default: .invalidDSF
        }
    }

    private static func from(_ error: SACDISOError) -> HiFiPlaybackError {
        switch error {
        case .missingStereoArea: .unsupportedArea
        case .unsupportedFrameFormat: .unsupportedSource
        default: .invalidSACDISO
        }
    }
}

extension HiFiPlaybackError: LocalizedError {
    public var errorDescription: String? { localizationKey }
}
