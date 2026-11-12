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

- macOS 15 Sequoia or later
- Xcode 16 or the matching Command Line Tools (`xcode-select --install`) to build

## Install

There is no notarized binary yet, so Lupa is built from source:

```bash
git clone https://github.com/pauloFroes/lupa.git
cd lupa
scripts/build-app.sh --install --open
```

`build-app.sh` compiles a release build, assembles `build/Lupa.app` with its icon, fonts and
translations, and signs it. `--install` quits any running copy and replaces
`/Applications/Lupa.app`; `--open` launches it and checks that the new copy is the one running.
Run the same command after `git pull` to update. Turn on **Open at Login** from the menu to start
Lupa with your Mac.

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

## Privacy

Lupa makes no network requests. Screenshots used for zoom and drawing stay in memory; nothing is
written to disk unless you save an image or record a video, and recordings go only to the folder
you choose.

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
