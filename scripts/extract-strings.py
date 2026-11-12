#!/usr/bin/env python3
"""List the localization keys used in Sources/ as the Swift compiler derives them.

Covers `String(localized:)` and the SwiftUI initializers that take a `LocalizedStringKey`
literal. String interpolations become `%@`; the codebase only interpolates `String`s into
localized text so that every key uses the same specifier.

Usage: scripts/extract-strings.py [--check Resources/pt-BR.lproj/Localizable.strings]
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CALLS = r"(?:String\(\s*localized:|Text\(|Button\(|toggleRow\(|eyebrow\(|section\(|\.help\(|\.accessibilityLabel\(|LimeToggle\(label:)"
SINGLE = re.compile(CALLS + r'\s*"((?:[^"\\]|\\.)*)"')
MULTI = re.compile(CALLS + r'\s*(?:localized:\s*)?"""\n(.*?)\n\s*"""', re.S)
INTERP = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")


def normalize(literal: str) -> str:
    return INTERP.sub("%@", literal).replace('\\"', '"')


def keys() -> set[str]:
    found = set()
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        text = path.read_text()
        for match in MULTI.finditer(text):
            lines = match.group(1).split("\n")
            indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
            found.add(normalize("\n".join(l[indent:] for l in lines)))
        for match in SINGLE.finditer(text):
            found.add(normalize(match.group(1)))
    return {k for k in found if k.strip() and re.search(r"[A-Za-z]", k)}


def table(path: pathlib.Path) -> dict[str, str]:
    pattern = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)
    unescape = lambda s: s.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")
    return {unescape(k): unescape(v) for k, v in pattern.findall(path.read_text())}


def main() -> int:
    used = keys()
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        translated = table(pathlib.Path(sys.argv[2]))
        missing = sorted(used - translated.keys())
        unused = sorted(translated.keys() - used)
        for key in missing:
            print(f"missing: {key!r}")
        for key in unused:
            print(f"unused:  {key!r}")
        return 1 if missing or unused else 0
    for key in sorted(used):
        print(repr(key))
    return 0


if __name__ == "__main__":
    sys.exit(main())
