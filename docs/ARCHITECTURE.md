# Architecture

Lupa is a single-process AppKit app built with Swift Package Manager, without an Xcode project.
`scripts/build-app.sh` turns the SwiftPM executable into a signed `.app` bundle. It runs as an
accessory app (`LSUIElement`): a status item, no Dock icon and no main window.

## Modes

`AppDelegate` owns the status item and the global shortcuts and switches between four modes. At
most one overlay is on screen at a time, except live drawing, which sits on top of live zoom.

| Mode | Type | How it works |
| --- | --- | --- |
| Zoom and draw | `ZoomDrawView` in an `OverlayWindow` | Takes one screenshot with `SCScreenshotManager` and draws a scaled crop of it. Drawing freezes the crop and keeps a list of `Shape`s with an undo stack. |
| Live drawing | `ZoomDrawView` without a snapshot | The same view, transparent, over live zoom. No hints are drawn because they would be recorded. |
| Live zoom | `LiveZoomController` | An `SCStream` of the display, minus Lupa's own windows, rendered into a click-through window and transformed every display-link frame. |
| Break | `BreakTimerView` | A full-screen countdown. |
| Recording | `RecordingController` + `ScreenRecorder` | A panel, optional area selection and countdown, then an `SCStream` written by `AVAssetWriter`. While recording, live zoom runs in auto-zoom mode. |

Overlays use `OverlayWindow` (borderless, `.screenSaver` level, on every Space). Overlays that need
the keyboard activate Lupa and restore the previously active app on exit through `FocusRestorer`.

## Input

- **Global shortcuts** use Carbon's `RegisterEventHotKey` (`HotKeyCenter`), which needs no
  Accessibility permission. Live zoom never takes keyboard focus, so its keys (`⌃+`, `⌃-`, `⌃0`,
  `Esc`) are registered as hot keys only while it runs.
- **Gestures and clicks outside Lupa** use `EventTap`, a wrapper over a session `CGEventTap`.
  With Accessibility granted, live zoom swallows pinch and `⌃`-scroll, and recording listens to
  clicks. Without it, a global `NSEvent` monitor observes the same events but cannot swallow them.

## Live zoom rendering

The stream delivers `IOSurface`s that are assigned directly to a `CALayer`'s `contents`, so frames
never touch the CPU. Each display-link tick:

1. advances `LiveCursor`, a spring that follows the mouse;
2. advances the zoom spring, in log space so 2×→4× feels as long as 4×→8×;
3. moves the camera so the cursor stays centered, never letting camera lag push it into the outer
   10% of the visible area, and clamping at the screen edges;
4. applies a single transform to the content layer, skipped when nothing changed, because every
   change makes the WindowServer recomposite the whole screen.

The real cursor is hidden and `LiveCursor` draws a magnified copy where the real pointer lands in
the zoomed image. Hiding the cursor from a background app needs a private SkyLight call; see
`SystemCursor`, which degrades to a visible cursor if the symbol is missing.

## Recording pipeline

`ScreenRecorder` owns one serial queue. Every `SCStream` callback, writer call and timer runs on
it, so the writer state needs no locks.

- **Video** frames are appended as they come. ScreenCaptureKit sends nothing while the screen is
  still, so a timer repeats the last frame to keep a constant frame rate.
- **Audio**: the microphone and system audio each get a track, with the microphone first.
- **Pause** shifts all later timestamps back by the paused duration instead of splitting files.
- **Click sounds** are synthesized (`ClickSound`) and either mixed into the first audio track
  (`ClickMixer`) or written to a track of their own (`ClickSoundTrack`) when there is no other audio.
- The recording control bar is excluded from the capture by window ID; everything else, including
  overlays and the camera bubble, is recorded.

## Persistence

`Preferences` stores settings in `UserDefaults`. `RecordingOptions` is a `Codable` blob; fields
added later must be optional or have a default so older data still decodes. Keys are stable and
must not be renamed.

## Localization

English strings are the keys (`String(localized:)` and SwiftUI literals). Translations live in
`Resources/<language>.lproj`, which `build-app.sh` copies into the bundle. A test checks that every
translation keeps its format specifiers, and `scripts/extract-strings.py --check` makes sure no key
is missing or stale.

## Concurrency

UI and AppKit state live on the main thread. Capture callbacks arrive on private queues and hop to
the main queue (`LiveZoomController`) or stay on the recorder's queue (`ScreenRecorder`). The
package uses the Swift 5 language mode because AppKit, AVFoundation and ScreenCaptureKit
callbacks are not yet annotated for strict concurrency; moving to Swift 6 mode is a welcome
contribution.
