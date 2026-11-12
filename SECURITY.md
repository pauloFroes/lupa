# Security Policy

## Supported versions

Only the latest release on `main` receives security fixes.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/pauloFroes/lupa/security/advisories/new)
rather than in a public issue. Include the macOS version, the Lupa version or commit, and steps to
reproduce.

You can expect an acknowledgement within a week. Once a fix is available, the advisory is
published with credit to the reporter, unless you prefer otherwise.

## Scope

Lupa runs locally, makes no network requests and asks for Screen Recording, and optionally
Microphone, Camera and Accessibility permissions. Issues that let another process abuse those
permissions through Lupa, or that leak captured screen content, are in scope.
