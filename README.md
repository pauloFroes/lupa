# Lupa

[![CI](https://github.com/pauloFroes/lupa/actions/workflows/ci.yml/badge.svg)](https://github.com/pauloFroes/lupa/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)

**Zoom, annotate and record your screen while you teach or present on a Mac.**

[Leia em português](README.pt-BR.md)

Lupa ("magnifying glass" in Portuguese) lives in the menu bar and stays out of the way until you
press a shortcut. It zooms into any part of the screen, lets you draw and type on top of it, puts a
break timer up for the room, and records all of it in high quality with your voice, system audio
and camera. The idea comes from [ZoomIt](https://learn.microsoft.com/sysinternals/downloads/zoomit),
rebuilt natively for macOS.

- **Zoom** around the pointer, either frozen or live while you keep using your apps.
- **Annotate** with pen, highlighter, lines, arrows, shapes, text and a white or black board.
- **Record** at Retina resolution, up to 60 fps, in HEVC, H.264 or ProRes, with zoom-on-click.
- **Take a break** with a full-screen countdown the audience can read from the back row.

It is a native Swift app with no dependencies, no network access and no telemetry.

## Requirements

- macOS 15 Sequoia or later, on Apple silicon or Intel
- Swift 6.0 or later: Xcode 16+, or just the Command Line Tools (`xcode-select --install`)
- Git

## Install

Lupa is built from source. There is no notarized binary.

```bash
git clone https://github.com/pauloFroes/lupa.git
cd lupa
scripts/build-app.sh --install --open
```

A magnifying glass appears in the menu bar. Press `⌃1`, allow **Screen & System Audio Recording**
when macOS asks, and open Lupa again.

`build-app.sh` compiles a release build, assembles `build/Lupa.app` with its icon, fonts and
translations, and signs it with a local certificate (see [Permissions](#permissions)). The flags:

| Flag | Effect |
| --- | --- |
| `--install` | Quits any running copy and replaces `/Applications/Lupa.app`. |
| `--open` | Launches the app and checks that the new copy is the one running. |
| `--universal` | Builds for both Apple silicon and Intel (needs Xcode). |

To update, pull and run the same command:

```bash
git pull && scripts/build-app.sh --install --open
```

Turn on **Open at Login** from the menu to start Lupa with your Mac. To uninstall, quit Lupa and
delete `/Applications/Lupa.app`; `tccutil reset All io.github.paulofroes.lupa` removes its
permissions.

## Getting started

A five-minute tour of what Lupa does. Every shortcut is listed under [Usage](#usage).

1. **Zoom in on a detail.** Press `⌃1`. The screen freezes and zooms around the pointer; scroll or
   pinch to zoom further and move the mouse to look around. Press `Esc` to leave.
2. **Point something out.** Press `⌃2` (or click while zoomed) and drag to draw. Press `R`, `G` or
   `B` to change color, `5` for arrows, `T` to type, `W` for a whiteboard, `E` to erase everything.
   `H` shows every drawing shortcut on screen. `Esc` leaves.
3. **Zoom while you work.** Press `⌃4` for live zoom: the zoom follows the pointer and your clicks
   reach the app below. `⌃+` and `⌃-` change the zoom; `⌃4` or `Esc` turns it off.
4. **Record a lesson.** Press `⌃5` to open the recording panel:
   - choose **Full screen** or drag an **Area**;
   - turn on **Microphone** and watch the level meter move as you speak;
   - turn on **Camera bubble** and pick a camera in the preview;
   - under **Save to**, click **Change…** to pick a folder (the default is `~/Movies/Lupa`);
   - optionally turn on **Show clicks** (rings) and **Click sound**.

   Click **Record**. After a 3-second countdown, every click zooms in on where you clicked and the
   view eases back out when the mouse rests; `fn`-click clicks without zooming. Press `⌃2` to draw
   over the moving screen and `Esc` to clear it, hold `⌥` to drag the camera bubble, and `⌃⇧5` to
   pause. Press `⌃5` again to stop; a panel offers to open the video or show it in Finder.
5. **Take a break.** Press `⌃3` for a full-screen countdown; `↑` `↓` change it by a minute.

Lupa's settings (`⌘,` with its menu open) change the shortcuts, the initial zoom, the pen color,
the live zoom cursor and the break length.

## Usage

| Shortcut | Mode | What it does |
| --- | --- | --- |
| `⌃1` | Zoom | Freezes the screen and zooms around the pointer. Scroll, pinch or press `↑` `↓` to change the zoom; move the mouse to pan. Click to start drawing right there. |
| `⌃2` | Draw | Draws on the frozen screen, or on the zoom if you came from `⌃1`. While recording or in live zoom, draws over the live screen instead. |
| `⌃3` | Break | Full-screen countdown. `↑` `↓` add or remove a minute, `Space` pauses. |
| `⌃4` | Live zoom | Zooms around the pointer while you keep working; clicks go to the app below. Pinch, `⌃`-scroll, `⌃+` and `⌃-` zoom between 1× and 8×; `⌃0` resets. |
| `⌃5` | Record | Opens the recording panel; while recording, stops. `⌃⇧5` pauses and resumes. |

`Esc` leaves any mode, except live zoom during a recording, where `Esc` stays with your apps.
All shortcuts can be changed in **Settings…** (`⌘,` with the menu open),
along with the initial zoom, the initial pen color, the live zoom cursor and the break length.

> `⌃1`–`⌃5` clash with "Switch to Desktop 1–5" when those Mission Control shortcuts are enabled
> in System Settings › Keyboard › Keyboard Shortcuts. Change one or the other.

### Drawing

| Key | Action |
| --- | --- |
| `R` `G` `B` `O` `Y` `P` | Red, green, blue, orange, yellow, pink. Add `⇧` for a highlighter. |
| `1`–`5` | Pen, line, rectangle, ellipse, arrow. The choice sticks until you change it. |
| hold `⇧` / `⌃` or `⌘` / `⌥` / `⌃⇧` | Line / rectangle / ellipse / arrow for the current drag only. |
| `T` | Type text at the pointer (dead keys and input methods work); `Esc` finishes. |
| scroll or pinch | Stroke width, or font size while typing. |
| `X` | Eraser that removes whole items; `⌥⌘`-click erases one item without switching tools. |
| `E` / `⌘Z` | Erase everything / undo, including erasing. |
| `W` / `K` | White / black board. |
| `⌘C` / `⌘S` | Copy the image / save a PNG to the Desktop. |
| `H` | Show or hide the shortcut overlay. |
| right-click | Back to zoom (when you came from `⌃1`) or exit. |

### Recording

The `⌃5` panel chooses the full screen or an area, system audio, microphone (on its own track,
with a live level meter), a camera bubble, click rings, an optional click sound, quality, frame
rate and output folder. After a 3-second countdown Lupa records at the display's native
resolution, and the menu bar icon turns into a red dot with the elapsed time.

- **Zoom on click.** Recording runs inside live zoom: a click zooms in to the initial zoom level
  and the view eases back to 1× after the mouse rests for 2.5 s. `fn`-click clicks without zooming.
- **Draw while recording.** `⌃2` draws over the moving screen without freezing it; `Esc` clears
  the drawing and returns the mouse to your apps.
- **Camera bubble.** Glides out of the way when the pointer heads for it and comes back later.
  Hold `⌥` to drag it; its position is remembered.
- **Files.** `.mov` in `~/Movies/Lupa` by default, at a constant frame rate. The microphone is the
  first audio track, so players that only play one track play your voice.
- **Quality.** High (HEVC), Compatible (H.264) or Maximum (ProRes 422, large files for editing).

There is no timeline editor; to trim the start and end, open the file in QuickTime Player (`⌘T`).

## Permissions

| Permission | Needed for |
| --- | --- |
| Screen & System Audio Recording | Required. Zoom and drawing work on a screenshot taken when you press the shortcut; recording captures the screen. |
| Microphone, Camera | Only when turned on in the recording panel. |
| Accessibility | Optional. Lets live zoom swallow pinch and `⌃`-scroll so the app below does not zoom too, and makes zoom-on-click more reliable. |

Open Lupa again after granting Screen Recording.

macOS ties these permissions to the app's code signature. So that they survive rebuilds,
`build-app.sh` creates a self-signed **Lupa Local Signing** certificate in your login keychain on
first run (`scripts/make-signing-cert.sh`) and always signs with it. When the signature does
change, `--install` resets the old grants and asks you to allow Lupa once more. If Lupa shows as
allowed but still asks, remove it from the list with `−` and open it again, or run:

```bash
tccutil reset ScreenCapture io.github.paulofroes.lupa
```

To sign with an Apple certificate instead, export `LUPA_SIGN_IDENTITY="Apple Development: …"`
before running the script; `LUPA_SIGN_IDENTITY=-` signs ad hoc.

## Security and privacy

Lupa asks for broad permissions, so here is exactly what it does with them. Every claim below can
be checked in the source.

- **No network access.** Lupa makes no network requests: no telemetry, no analytics, no update
  checks. Nothing you capture or record leaves your Mac.
- **No third-party code.** The package has no dependencies; Lupa links only Apple frameworks.
- **Screen content stays local.** Screenshots used for zoom and drawing live in memory. Files are
  written only when you ask: saved images go to the Desktop, recordings to `~/Movies/Lupa` or the
  folder you choose. The only file Lupa ever deletes is the partial video of a recording that
  failed.
- **No keyboard monitoring.** Shortcuts are registered with the system hot key API, so Lupa only
  receives the shortcuts you assign. It never sees other keystrokes.
- **Mouse clicks are only observed.** Click-to-zoom, the click sound and the live zoom cursor
  watch mouse buttons through listen-only event taps or monitors, which cannot block or change
  events, and never store where you click. Live zoom is the only
  feature that consumes input, and only pinch gestures and `⌃`-scroll while it is on. Taps are
  torn down when the feature stops.
- **Logs hold no content.** Lupa logs internal state (zoom level, hot key registration, errors) to
  the unified log. It never logs keystrokes, text or screen content.
- **Opt-in device access.** Microphone and camera are requested only when you turn them on in the
  recording panel. Open at login stays off until you enable it, and uses the system login item API.
- **One private API.** Hiding the cursor during live zoom uses a private WindowServer call,
  resolved at run time. It only toggles cursor visibility for Lupa's own connection; see
  [Development](#development).
- **Self-signed certificate.** `build-app.sh` creates a code-signing-only certificate in your
  login keychain (see [Permissions](#permissions)). It is not trusted as a root or for TLS, and
  only `codesign` may use its key. You can delete it in Keychain Access at any time.
- **Not notarized.** Lupa is not notarized by Apple. Building from source, as described in
  [Install](#install), lets you review exactly what runs.

To remove every trace, quit Lupa, delete `/Applications/Lupa.app` and run
`tccutil reset All io.github.paulofroes.lupa`.

Found a vulnerability? Please report it privately as described in [SECURITY.md](SECURITY.md).

## Development

```bash
swift build          # debug build
swift test           # unit tests (needs Xcode, not just the Command Line Tools)
swift format lint --strict --recursive Sources Tests
scripts/build-app.sh # assemble and sign build/Lupa.app
```

The [architecture overview](docs/ARCHITECTURE.md) explains how the pieces fit together, and
[CONTRIBUTING.md](CONTRIBUTING.md) covers the workflow, code style and commit conventions.

Lupa hides the system cursor during live zoom through a private SkyLight API, resolved at run
time. If that API disappears in a future macOS, live zoom keeps working with the regular cursor
visible. See `SystemCursor.swift`.

## License

Code released under the [MIT License](LICENSE). The bundled Bricolage Grotesque, Manrope and
JetBrains Mono fonts are distributed under the SIL Open Font License; see `Resources/Fonts/`.
