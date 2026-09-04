# Agent Instructions for Hi-Fi

## Project Overview

Hi-Fi is the first-party foofoil extension for high-resolution and DSD local playback. It is not a standalone player and cannot run without foofoil.

This repository owns DSF/DFF/SACD parsing, DoP and CoreAudio HAL output, device selection, exclusive/hog handling, and the `foofoil_extension_create` runtime that speaks JSON value messages. Playback lists and menus are projected through foofoil's host UI; do not add a private sidebar or custom host views.

Current scope is raw DSF/DFF and uncompressed stereo SACD ISO → DoP → CoreAudio HAL. Stereo DSD64 is hardware-verified for DSF/DFF and for uncompressed stereo SACD ISO (list, seek, sound, and two-track auto-advance on SMSL); DSD256 is also hardware-verified, while DSD128 remains pending. 5.0 DFF uses native/5.1/7.1 DoP when the device exposes that carrier format, otherwise MLFT/MRGT stereo; multichannel hardware verification is deferred until a suitable surround DoP DAC is available. Do not treat DSD → PCM fallback, DST, SACD multichannel, or Registry install as already done. Device unplug/busy/hog/sleep recovery has passed real-DAC verification. Read `docs/hifi-phase0-dsf-playback-handoff.md` section 4 before changing HAL, DoP, SACD sector packing, or device lifecycle code.

## Core Principles

1. **Keep the extension focused on audio the system cannot already do well.** Ordinary MP3/AAC playback remains a host fallback unless Hi-Fi is explicitly chosen.
2. **Use CoreAudio, AudioToolbox, and Foundation first.** Do not add FFmpeg, a third-party codec package, or a custom plugin host unless native APIs cannot meet the requirement.
3. **Never leak codec or HAL types across the Extension API.** The host sees Manifest data, JSON sessions, and the C ABI only.
4. **Release hardware reliably.** Hog Mode, IOProcs, and security-scoped file access must be stopped on pause-to-close, device change, session replacement, and process teardown.
5. **Prefer incremental change.** Reuse existing stream, encoder, and engine types. Keep diffs focused.

## Architecture

- `HiFiExtensionCore` holds parsers, streams, DoP encoding, device catalog, and the HAL engine.
- `HiFiExtensionRuntime` exports `foofoil_extension_create` and maps JSON requests/commands onto Core. Do not import SwiftUI or pass `NSView` / in-process objects through the ABI.
- Identify output devices by stable CoreAudio UID, not transient `AudioObjectID`.
- Persist only values that survive device reconnect; do not persist one-shot object IDs.
- Keep real-time audio work off the main thread. Do not allocate or lock in the HAL IOProc beyond the existing ring-buffer path.
- Respect Swift concurrency isolation. Prefer structured concurrency over detached or unbounded background work.
- Preserve existing documentation comments. Add concise Chinese comments for HAL, DoP, hog, or sandbox workarounds that are not self-evident. Do not comment obvious code.

## Dependencies and Assets

- This project is distributed under the MIT License. New code and assets must be distributable under that license.
- The default decision for a new third-party dependency is **no**.
- Do not commit `.build/`, plugin build scratch directories, `*.foofoilextension` products, or machine-specific project state.

## Testing and Verification

- Add or update focused tests for container parsing, DoP packing, stream/seek alignment, and device catalog stability.
- Use the Swift Testing framework under `Tests/HiFiExtensionCoreTests`.
- Run before considering a parser or encoder change complete:

  ```sh
  swift test
  ```

- Use `swift run hifi-inspect` and `swift run hifi-hal-probe` for container and device checks that unit tests cannot cover.
- After a change that affects playback or the extension bundle, rebuild from the sibling foofoil repo with `./run` (not Xcode ⌘R) so the Debug plugin is injected, then open a Stereo DSD64 `.dsf` on a DoP-capable DAC. Report what was verified. Skip the app launch only if the change cannot affect runtime behavior.
- Treat new warnings as defects. Do not silence warnings without addressing or documenting the underlying reason.

## Change Discipline

- Inspect the surrounding engine, runtime JSON, and `ExtensionManifest.json` before editing so they stay consistent.
- When creating a file with a `Created by` header, use the human identity returned by `git config user.name`. Never use an agent, model, assistant, or tool name.
- Preserve unrelated user changes in the working tree.
- Do not change the package platform, bundle identifier `app.foofoil.extension.hifi`, or `FoofoilExtensionExecutionModel` unless the task explicitly requires it.
- Keep decoding and device control on-device. Do not add analytics, telemetry, remote processing, or network services.

## Git Commit Guidelines

- Write commit messages in English.
- Follow Conventional Commits and keep the subject concise, for example: `fix: release hog mode when the session closes`.
- Keep each commit focused on one coherent change and do not include generated or unrelated files.
