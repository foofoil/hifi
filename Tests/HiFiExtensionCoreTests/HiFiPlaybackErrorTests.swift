import CoreAudio
import Foundation
import Testing
@testable import HiFiExtensionCore

@Suite
struct HiFiPlaybackErrorTests {
    @Test func mapsProbeAndContainerFailuresToStableCodes() {
        #expect(HiFiPlaybackError.from(CoreAudioHALFormatProbeError.deviceNotFound("uid")) == .deviceDisconnected)
        #expect(HiFiPlaybackError.from(CoreAudioHALFormatProbeError.deviceInUse(99)) == .deviceBusy)
        #expect(HiFiPlaybackError.from(CoreAudioHALFormatProbeError.hogModeAcquireFailed) == .exclusiveModeFailure)
        #expect(HiFiPlaybackError.from(CoreAudioHALFormatProbeError.noDoPTransport(2_822_400)) == .unsupportedDoPRate)
        #expect(HiFiPlaybackError.from(CoreAudioHALFormatProbeError.unsupportedDSDRate(48_000)) == .unsupportedDoPRate)
        #expect(HiFiPlaybackError.from(CoreAudioHALFormatProbeError.ioStart(-1)) == .outputInitializationFailure)
        #expect(HiFiPlaybackError.from(DSDContainerError.truncated) == .invalidDSF)
        #expect(HiFiPlaybackError.from(DSDContainerError.invalidFormat) == .invalidDSF)
        #expect(HiFiPlaybackError.from(DSDContainerError.unsupportedCompression("DST ")) == .unsupportedSource)
        #expect(HiFiPlaybackError.from(SACDISOError.truncated) == .invalidSACDISO)
        #expect(HiFiPlaybackError.from(SACDISOError.missingStereoArea) == .unsupportedArea)
        #expect(HiFiPlaybackError.from(HALDSFPlaybackError.invalidStartPosition) == .seekIndexFailure)
        #expect(HiFiPlaybackError.from(DSDStreamError.seekMustBeByteAligned) == .seekIndexFailure)
        #expect(
            HiFiPlaybackError.from(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
                == .resourceAuthorizationFailure
        )
    }

    @Test func localizationKeysAreStableForHostChrome() {
        #expect(HiFiPlaybackError.deviceDisconnected.localizationKey == "Hi-Fi Device Disconnected")
        #expect(HiFiPlaybackError.deviceBusy.localizationKey == "Hi-Fi Device Busy")
        #expect(HiFiPlaybackError.exclusiveModeFailure.localizationKey == "Hi-Fi Exclusive Mode Failed")
        #expect(HiFiPlaybackError.outputInitializationFailure.localizationKey == "Hi-Fi Output Initialization Failed")
        #expect(HiFiPlaybackError.unsupportedDoPRate.localizationKey == "Hi-Fi Unsupported DoP Rate")
        #expect(HiFiPlaybackError.from(HiFiPlaybackError.deviceBusy) == .deviceBusy)
        #expect(HiFiPlaybackError(localizationKey: "Hi-Fi Device Disconnected") == .deviceDisconnected)
    }

    @Test func connectedOutputDevicesReportAlive() throws {
        let devices = try CoreAudioDeviceCatalog.outputDevices()
        for device in devices where device.isConnected {
            let deviceID = try CoreAudioHALFormatProbe.resolveDeviceID(uid: device.id)
            #expect(CoreAudioHALFormatProbe.isDeviceAlive(deviceID))
        }
        #expect(!CoreAudioHALFormatProbe.isDeviceAlive(AudioDeviceID(kAudioObjectUnknown)))
    }
}
