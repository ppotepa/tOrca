#!/usr/bin/env python3
"""Detect common localization regressions in TorChat presentation code."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOBILE_LIB = ROOT / "mobile" / "lib"
ANDROID = ROOT / "mobile" / "android" / "app" / "src" / "main"

PRESENTATION_ROOTS = (
    MOBILE_LIB / "features",
    MOBILE_LIB / "shared" / "widgets",
    MOBILE_LIB / "locales" / "presentation",
    MOBILE_LIB / "locales" / "application",
    MOBILE_LIB / "main.dart",
)

FORBIDDEN_SNIPPETS = {
    "LocalizedUiCopy": "obsolete localization proxy",
    "localized_ui_copy.dart": "obsolete localization proxy import",
    "localeName.toLowerCase().startsWith('pl')": "manual locale branching",
    'localeName.toLowerCase().startsWith("pl")': "manual locale branching",
    "lookupAppLocalizations(const Locale('pl'))": "hard-coded Polish fallback",
}

POLISH_PRESENTATION_WORDS = re.compile(
    r"(?:Nie udało|Zaproszenie|Oczekujące|Zakończono|Ustawienia|Kontakty|Czaty|"
    r"Pokaż|Ukryj|Zapisz|Anuluj|Spróbuj|Łączenie|Uruchamianie|Gotowy|"
    r"Fingerprint niedostępny|Brak kontaktów)",
    re.IGNORECASE,
)

RAW_EXCEPTION_PATTERNS = (
    re.compile(r"show(?:Error|Warning|Info|Success)\s*\([^\n]*error\.toString\("),
    re.compile(r"(?:Text|StatusBanner|InlineStatus)\s*\([^\n]*error\.toString\("),
    re.compile(r"_error\s*=\s*error\.toString\("),
)

ENUM_LABEL_PATTERN = re.compile(
    r"(?:Text|subtitle|title|label|tooltip|semanticLabel)\s*[:(][^\n]*\.name\b"
)


def iter_sources() -> list[Path]:
    files: list[Path] = []
    for root in PRESENTATION_ROOTS:
        if root.is_file():
            files.append(root)
        elif root.is_dir():
            files.extend(root.rglob("*.dart"))
    if ANDROID.is_dir():
        files.extend((ANDROID / "kotlin").rglob("*.kt"))
        files.extend((ANDROID / "AndroidManifest.xml",))
    return sorted({path for path in files if path.is_file()})


def report(path: Path, line_number: int, message: str, line: str) -> None:
    relative = path.relative_to(ROOT)
    print(
        f"{relative}:{line_number}: localization regression: {message}\n"
        f"    {line.strip()}",
        file=sys.stderr,
    )


def main() -> int:
    failures = 0
    for path in iter_sources():
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()
        for line_number, line in enumerate(lines, start=1):
            for snippet, message in FORBIDDEN_SNIPPETS.items():
                if snippet in line:
                    report(path, line_number, message, line)
                    failures += 1
            if path.suffix == ".dart" and POLISH_PRESENTATION_WORDS.search(line):
                if line.lstrip().startswith("//"):
                    continue
                report(path, line_number, "Polish copy outside ARB", line)
                failures += 1
            for pattern in RAW_EXCEPTION_PATTERNS:
                if pattern.search(line):
                    report(path, line_number, "raw exception displayed to user", line)
                    failures += 1
            if ENUM_LABEL_PATTERN.search(line):
                report(path, line_number, "enum name used as presentation copy", line)
                failures += 1

    if failures:
        print(f"frontend localization check failed: {failures} issue(s)", file=sys.stderr)
        return 1
    print("frontend localization check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
