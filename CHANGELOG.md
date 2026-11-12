# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-11-12

### Added

- English user interface, with Brazilian Portuguese chosen automatically when macOS is set to it.
- Recording runs inside live zoom: a click zooms in, and the view eases back to 1× when the mouse
  rests. `fn`-click clicks without zooming.
- Live drawing (`⌃2`) over the moving screen while recording or in live zoom.
- Camera bubble that glides away from the pointer, with a camera picker and live preview.
- Microphone level meter in the recording panel.
- Optional click sound mixed into the recording's first audio track.
- Floating recording bar with elapsed time, pause and stop, and a `⌃⇧5` pause shortcut.
- Choice of output folder, and the last recording area and bubble position are remembered.
- Unit tests, CI (build, tests, `swift format`, ShellCheck, translation check) and contributor
  documentation.

### Changed

- The microphone is now the first audio track, so single-track players play the voice.
- Zoom-on-click listens through a listen-only event tap when Accessibility is granted, falling back
  to a global event monitor.
- Logging moved to `os.Logger` with `hotkeys`, `live-zoom`, `recording` and `cursor` categories;
  per-event logs are at the debug level.
- Recordings and saved images are named `Lupa <date> at <time>` (localized).

### Removed

- Live captions and transcription, which required an OpenAI API key.

### Fixed

- Toggles in the recording panel announced themselves to VoiceOver as "Open at login".
- Event taps were not invalidated when stopped, leaking a Mach port per recording.
- The temporary password protecting the signing certificate export was guessable.

## [0.2.0] - 2026-11-04

### Added

- Screen recording to `.mov` in HEVC, H.264 or ProRes, with system audio and microphone on
  separate tracks, area selection and a countdown.
- `scripts/build-app.sh` to assemble, sign and install the app bundle.

## [0.1.0] - 2026-11-04

### Added

- Frozen zoom, drawing with pens, shapes and text, break timer and live zoom.
- Configurable global shortcuts and Settings window.

