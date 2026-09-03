# Hi-Fi for foofoil

Advanced local audio playback extension for [foofoil](https://github.com/foofoil/foofoil). **Requires foofoil.**

Hi-Fi is a first-party foofoil extension. It is not a standalone player. Install foofoil first, then install Hi-Fi from inside the app (or load a development bundle while building from source).

The extension adds high-resolution and DSD playback that the lightweight foofoil core does not ship: DSF/DFF, SACD ISO/DST (in progress), enhanced handling of formats the system already plays, output-device selection, DoP, and music-oriented session features. Playback lists are projected through foofoil's shared navigator, not a private sidebar.

[简体中文](README.zh-CN.md)

## Status

The current tree is the Phase 0 development prototype extracted from foofoil's `hifi-ext` branch:

- DSF / raw DFF → DoP → CoreAudio HAL → USB DAC
- Stereo DSD64 DSF and stereo DFF verified on an SMSL DAC; 5.0 DFF uses surround DoP when the device allows it, otherwise a stereo fold
- Host session commands for play, pause, progress, output-device selection, and device release on close

Not yet a shipping release. Remaining work includes DSD → PCM fallback, DST / SACD ISO, dedicated metadata, session restore, DSD128/256 hardware regression, process isolation, and signed/notarized GitHub Releases for in-app install. Device disconnect/hog/sleep recovery is implemented and waiting on real-DAC confirmation.

See [docs/hifi-phase0-dsf-playback-handoff.md](docs/hifi-phase0-dsf-playback-handoff.md) and [docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md](docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md).

## Requirements

- [foofoil](https://github.com/foofoil/foofoil) (host app)
- macOS 15 or later, Apple silicon
- Xcode / Swift 6 for building from source

Compatible Extension API: v1 (`extensionAPI.min` / `max` in `ExtensionManifest.json`).

## Local Playback Test

Hi-Fi is not in the in-app Registry yet. For a real hardware check, keep `hifi` as a sibling of `foofoil` and start the host with its `./run` script, which builds this package and injects `Hi-Fi.foofoilextension` into the Debug app:

```sh
cd ../foofoil
./run
```

Then drop a Stereo DSD64 `.dsf` onto a foil, or File → Open. Use the in-window play/pause controls and the **Extensions** menu for output-device selection. Do not use Xcode ⌘R for this path: it builds foofoil without injecting the plugin.

To build the bundle by itself:

```sh
./build-plugin /tmp/foofoil-hifi-plugin
```

This produces `Hi-Fi.foofoilextension`. Production installs will go through foofoil's Extension Manager and will not be bundled inside `foofoil.app`.

## Tests and Tools

```sh
swift test
swift run hifi-inspect --help
swift run hifi-hal-probe
```

`HiFiExtensionRuntime` exports `foofoil_extension_create` and exchanges JSON value messages with the host. It does not import SwiftUI or pass in-process views across the ABI.

## Related Repositories

| Repository | Role |
| --- | --- |
| [foofoil](https://github.com/foofoil/foofoil) | Host app. Install this first. |
| [extension-kit](https://github.com/foofoil/extension-kit) | Extension API contracts, ABI header, and Manifest schema |

## License

Hi-Fi is licensed under the [MIT License](LICENSE), copyright © 2026 Beijing Memory Vision Technology Co., Ltd.
