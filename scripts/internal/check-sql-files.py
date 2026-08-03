#!/usr/bin/env python3
"""Static SQL isolation guard for TorChat.

The checker is deliberately conservative: it reports probable SQL literals and
boundary leaks with path/line information. Existing findings are emitted as a
ratchet report until the migration batches remove them.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

SQL_START = re.compile(r"\b(SELECT|INSERT|UPDATE|DELETE|WITH|CREATE|ALTER|DROP|TRIGGER|PRAGMA)\b", re.I)
SQL_LITERAL = re.compile(r"^(SELECT|INSERT|UPDATE|DELETE|WITH)(?:\s|\r?\n)", re.I)
INCLUDE = re.compile(r"include_str!\s*\(\s*\"([^\"]+\.sql)\"\s*\)")
CONNECTION_LEAK = re.compile(r"\.connection(?:_mut)?\(\)\s*\.\s*(?:execute|execute_batch|query|prepare)")


def rust_string_literals(text: str):
    pattern = re.compile(r'r#*"(?P<body>.*?)"#*|"(?P<plain>(?:\\.|[^"\\])*)"', re.S)
    for match in pattern.finditer(text):
        body = match.group("body") or match.group("plain") or ""
        start = text.count("\n", 0, match.start()) + 1
        yield body, start


def check_rust(path: Path, root: Path, test: bool) -> list[str]:
    findings: list[str] = []
    text = path.read_text(encoding="utf-8")
    for body, line in rust_string_literals(text):
        if SQL_LITERAL.match(body.lstrip()) and not body.lstrip().startswith("include_str"):
            findings.append(f"{path.relative_to(root)}:{line}: inline SQL literal")
    for match in CONNECTION_LEAK.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        if "storage" not in path.parts and "tests" not in path.parts:
            findings.append(f"{path.relative_to(root)}:{line}: connection API outside storage")
    return findings


def check_sql_file(path: Path, root: Path, client: bool, migrations: bool) -> list[str]:
    findings: list[str] = []
    text = path.read_text(encoding="utf-8")
    statements = [part.strip() for part in re.split(r";\s*(?:--[^\n]*)?", text) if part.strip()]
    if not migrations and len(statements) != 1:
        findings.append(f"{path.relative_to(root)}: expected one statement, found {len(statements)}")
    if not migrations:
        first = text.lstrip().upper()
        is_query = "/queries/" in path.as_posix() or "\\queries\\" in str(path)
        if is_query and re.match(r"(?:INSERT|UPDATE|DELETE)\b", first):
            findings.append(f"{path.relative_to(root)}: DML placed in queries")
        if client and re.search(r"\$\d+", text):
            findings.append(f"{path.relative_to(root)}: PostgreSQL placeholder in SQLite SQL")
        if not client and re.search(r"\?\d+", text):
            findings.append(f"{path.relative_to(root)}: SQLite placeholder in PostgreSQL SQL")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    findings: list[str] = []
    referenced: set[Path] = set()
    for source_root, test in ((root / "common/torchat-client-engine/src", False),
                              (root / "common/torchat-client-engine/tests", True),
                              (root / "server/torchat-server/src", False)):
        if source_root.exists():
            for path in source_root.rglob("*.rs"):
                text = path.read_text(encoding="utf-8")
                for include in INCLUDE.finditer(text):
                    candidate = (path.parent / include.group(1)).resolve()
                    if candidate.suffix.lower() == ".sql":
                        referenced.add(candidate)
                findings.extend(check_rust(path, root, test))
    for sql_root, client in ((root / "common/torchat-client-engine/sql", True),
                             (root / "server/torchat-server/sql", False)):
        for path in sql_root.rglob("*.sql"):
            findings.extend(check_sql_file(path, root, client, "migrations" in path.parts))
            if "migrations" not in path.parts and path.resolve() not in referenced:
                findings.append(f"{path.relative_to(root)}: orphan SQL file")
    if findings:
        print("[torchat] SQL isolation findings:")
        print("\n".join(sorted(set(findings))))
        print(f"[torchat] total findings: {len(set(findings))}")
        return 1 if args.strict else 0
    print("[torchat] SQL isolation check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
