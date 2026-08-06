#!/usr/bin/env python3
"""Static architecture guard for the Torca 0.3 boundaries.

This tool intentionally uses only the Python standard library so it can run in
local development and CI without restoring Rust or Flutter dependencies.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Violation:
    rule: str
    path: Path
    detail: str

    def render(self) -> str:
        return f"{self.rule}: {self.path.relative_to(ROOT)}: {self.detail}"


def source_files(root: Path, suffixes: tuple[str, ...]) -> Iterable[Path]:
    if not root.exists():
        return ()
    return (
        path
        for path in root.rglob("*")
        if path.is_file()
        and path.suffix in suffixes
        and not any(part in {"target", ".dart_tool", "build", "generated"} for part in path.parts)
    )


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def contains_any(text: str, needles: Iterable[str]) -> list[str]:
    return [needle for needle in needles if needle in text]


def check_flutter_platform_boundaries() -> list[Violation]:
    violations: list[Violation] = []
    feature_root = ROOT / "apps/mobile/flutter/lib/features"
    for path in source_files(feature_root, (".dart",)):
        text = read(path)
        for match in re.finditer(r"^import\s+['\"]([^'\"]*platform/[^'\"]*)['\"];", text, re.MULTILINE):
            violations.append(
                Violation(
                    "flutter.feature_platform_import",
                    path,
                    f"feature UI imports platform implementation {match.group(1)!r}",
                )
            )

    flutter_root = ROOT / "apps/mobile/flutter/lib"
    for path in source_files(flutter_root, (".dart",)):
        text = read(path)
        if "PlatformServices.current" in text:
            violations.append(
                Violation(
                    "flutter.global_platform_singleton",
                    path,
                    "use a provider-backed platform port instead",
                )
            )

    domain_async_roots = [
        feature_root,
        ROOT / "apps/mobile/flutter/lib/app",
    ]
    timer_allowlist = {
        Path("apps/mobile/flutter/lib/app/application_runtime_coordinator.dart"),
    }
    for scan_root in domain_async_roots:
        for path in source_files(scan_root, (".dart",)):
            text = read(path)
            if "Future.delayed" in text:
                violations.append(
                    Violation(
                        "flutter.domain_delay",
                        path,
                        "domain/application flow must be driven by snapshots or durable operations",
                    )
                )
            relative = path.relative_to(ROOT)
            if "Timer(" in text and relative not in timer_allowlist:
                violations.append(
                    Violation(
                        "flutter.domain_timer",
                        path,
                        "only presentation expiry timers are allowed",
                    )
                )
    return violations


def check_rust_storage_boundaries() -> list[Violation]:
    violations: list[Violation] = []
    packages = ROOT / "packages"
    sql_patterns = (
        re.compile(r'"\s*SELECT\s', re.IGNORECASE),
        re.compile(r'"\s*INSERT\s+INTO\s', re.IGNORECASE),
        re.compile(r'"\s*UPDATE\s+[A-Za-z_]', re.IGNORECASE),
        re.compile(r'"\s*DELETE\s+FROM\s', re.IGNORECASE),
    )
    for path in source_files(packages, (".rs",)):
        if "torchat-storage" in path.parts:
            continue
        text = read(path)
        if any(pattern.search(text) for pattern in sql_patterns):
            violations.append(
                Violation(
                    "rust.sql_outside_storage",
                    path,
                    "move parameterized SQL to packages/torchat-storage/sql",
                )
            )

    storage_trait = ROOT / "packages/torchat-runtime/src/storage.rs"
    if storage_trait.exists():
        text = read(storage_trait)
        silent_default = re.compile(
            r"fn\s+\w+\s*\([^;{}]*\)[^{;]*\{\s*Ok\s*\(\s*(?:\(\)|0|Vec::new\(\))\s*\)",
            re.DOTALL,
        )
        for match in silent_default.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            violations.append(
                Violation(
                    "rust.silent_storage_default",
                    storage_trait,
                    f"silent success/default near line {line}",
                )
            )
    return violations


def check_runtime_features() -> list[Violation]:
    violations: list[Violation] = []
    feature_root = ROOT / "packages/torchat-runtime/src/features"
    for path in source_files(feature_root, (".rs",)):
        text = read(path)
        for needle, rule in (
            ("SystemTime::now", "runtime.direct_system_clock"),
            (".into_iter().find(", "runtime.collection_point_lookup"),
            (".iter().find(", "runtime.collection_point_lookup"),
        ):
            if needle in text:
                violations.append(
                    Violation(rule, path, f"forbidden feature dependency {needle!r}")
                )
        for user_text in ("Nowa rozmowa", "Nie udało", "Połączenie", "Zaproszenie"):
            if user_text in text:
                violations.append(
                    Violation(
                        "runtime.user_facing_text",
                        path,
                        f"return a stable error/status code instead of {user_text!r}",
                    )
                )
    return violations


def check_engine_pipeline() -> list[Violation]:
    violations: list[Violation] = []
    engine_src = ROOT / "packages/torchat-client-engine/src"
    pipelines = sorted(
        path
        for path in engine_src.rglob("command_pipeline")
        if path.is_dir()
    )
    expected = engine_src / "actor/command_pipeline"
    if pipelines != [expected]:
        rendered = ", ".join(str(path.relative_to(ROOT)) for path in pipelines) or "none"
        violations.append(
            Violation(
                "engine.command_pipeline_count",
                engine_src,
                f"expected only {expected.relative_to(ROOT)}, found {rendered}",
            )
        )

    banned_legacy_calls = (
        "runtime.prepare_pending_send_effects(",
        "runtime.prepare_submit_pairing_code(",
        "runtime.commit_submitted_pairing(",
        "runtime.receive_pairing_offer(",
        "runtime.apply_pairing_peer_outcome(",
        "runtime.reconcile_outbox_pairing_contact(",
        "runtime.welcome_accepted(",
        "runtime.send_message_reply(",
        "runtime.retry_message(",
        "runtime.delete_message_local(",
    )
    for path in source_files(engine_src / "actor", (".rs",)):
        text = read(path)
        for needle in contains_any(text, banned_legacy_calls):
            violations.append(
                Violation(
                    "engine.legacy_runtime_call",
                    path,
                    f"route {needle[:-1]} through a feature facade",
                )
            )
    return violations


def check_required_contract_files() -> list[Violation]:
    required = (
        "docs/architecture/FFI-ABI.md",
        "common/client-engine-contract.json",
        "packages/torchat-runtime/src/error.rs",
        "packages/torchat-runtime/src/changes.rs",
        "packages/torchat-runtime/src/clock.rs",
        "packages/torchat-runtime/src/retry.rs",
        "packages/torchat-runtime/src/operations.rs",
    )
    return [
        Violation("architecture.required_file", ROOT / relative, "required boundary artifact is missing")
        for relative in required
        if not (ROOT / relative).exists()
    ]


def main() -> int:
    violations = [
        *check_flutter_platform_boundaries(),
        *check_rust_storage_boundaries(),
        *check_runtime_features(),
        *check_engine_pipeline(),
        *check_required_contract_files(),
    ]
    if violations:
        print("Architecture guard failed:", file=sys.stderr)
        for violation in sorted(violations, key=lambda item: item.render()):
            print(f"- {violation.render()}", file=sys.stderr)
        return 1
    print("Architecture guard passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
