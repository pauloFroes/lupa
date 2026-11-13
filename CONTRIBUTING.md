# Contributing to Lupa

Thanks for taking the time to contribute. Bug reports, fixes and focused improvements are all
welcome. For larger changes, please open an issue first so we can agree on the approach before you
spend time on it.

Issues and pull requests may be written in English or Portuguese.

## Getting started

You need macOS 15 or later and Xcode 16 (the Command Line Tools are enough to build, but `swift
test` needs Xcode).

```bash
git clone https://github.com/pauloFroes/lupa.git
cd lupa
swift build
swift test
scripts/build-app.sh --open    # assemble, sign and launch build/Lupa.app
```

Run the app from the bundle rather than with `swift run`: fonts, translations and the privacy
permissions all depend on the `.app` and its code signature. See the README for how the local
signing certificate keeps permissions stable across builds.

Logs go to the unified logging system:

```bash
log stream --predicate 'subsystem == "io.github.paulofroes.lupa"' --level debug
```

## Project layout

```
Sources/Lupa/
  App/         entry point, AppDelegate (status item, shortcuts, mode switching)
  Annotation/  frozen zoom and drawing overlay, shapes, text
  Break/       break timer
  Capture/     ScreenCaptureKit helpers, overlay window
  HotKeys/     Carbon hot keys, shortcuts, key names
  LiveZoom/    live zoom controller, HUD, cursor, gesture input
  Recording/   recorder, panels, camera bubble, click sounds
  Settings/    preferences and the Settings window
  Support/     small shared utilities (logging, event taps, springs)
  UI/          design tokens, shared SwiftUI components, HUD drawing
Resources/     Info.plist, fonts, *.lproj translations
Tests/         unit tests (Swift Testing)
scripts/       build, signing, icon and localization tooling
```

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) describes how the modes interact.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Keep the change focused. Unrelated refactors belong in their own pull request.
3. Add or update tests for logic that can be tested without a window server.
4. Run the checks below and try the change in the real app.
5. Open a pull request and fill in the template, including how you tested it.

### Checks

There is no hosted CI, so run all of these locally before opening a pull request:

```bash
swift format lint --strict --recursive Sources Tests Package.swift scripts/make-icon.swift
swift build -c release
swift test
shellcheck scripts/*.sh
scripts/extract-strings.py --check Resources/pt-BR.lproj/Localizable.strings
```

`swift format` ships with the Swift 6 toolchain; `swift format format -i -r Sources Tests` fixes
most findings. The configuration lives in `.swift-format`.

## Code style

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Comments explain *why*, not *what*. Use `///` doc comments for types and non-obvious members.
- Use `Log` (`os.Logger`) for diagnostics, never `print` or `NSLog`. Keep per-frame or per-event
  logging at `.debug`.
- Main-thread code stays on the main thread; capture and writer callbacks hop explicitly. The
  package uses the Swift 5 language mode until the frameworks it depends on are ready for strict
  concurrency.

## Localization

English is the development language and the source of every key. Wrap user-facing text in
`String(localized:)`, or pass a literal to SwiftUI views, which localize it automatically. Only
interpolate `String` values into localized text so every placeholder is `%@`.

After changing user-facing text, update `Resources/pt-BR.lproj/Localizable.strings` and run
`scripts/extract-strings.py --check Resources/pt-BR.lproj/Localizable.strings`. New languages are
welcome: add a `<language>.lproj` folder and list it under `CFBundleLocalizations` in
`Resources/Info.plist`.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/) in English, in the imperative
mood:

```
feat(recording): add a pause shortcut
fix(live-zoom): keep the cursor inside the visible area while zooming out
docs: explain the local signing certificate
```

Common types are `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci` and `chore`.
Scopes usually match a folder under `Sources/Lupa`.

## Reporting bugs and security issues

Use the issue templates for bugs and feature requests. Please do not report security issues in
public; see [SECURITY.md](SECURITY.md).

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
