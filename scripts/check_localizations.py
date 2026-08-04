#!/usr/bin/env python3
"""Validate TorChat ARB catalogs without requiring Flutter tooling."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "mobile" / "lib" / "locales" / "resources"
CATALOGS = {
    "en": RESOURCES / "app_en.arb",
    "pl": RESOURCES / "app_pl.arb",
}


def fail(message: str) -> None:
    print(f"localization error: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_catalog(locale: str, path: Path) -> dict[str, Any]:
    if not path.is_file():
        fail(f"missing {locale} catalog: {path.relative_to(ROOT)}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot parse {path.relative_to(ROOT)}: {error}")
    if not isinstance(data, dict):
        fail(f"catalog {path.relative_to(ROOT)} is not a JSON object")
    declared = data.get("@@locale")
    if declared != locale:
        fail(
            f"catalog {path.relative_to(ROOT)} declares locale {declared!r}, "
            f"expected {locale!r}"
        )
    return data


def message_keys(catalog: dict[str, Any]) -> set[str]:
    return {key for key in catalog if not key.startswith("@")}


def placeholder_names(catalog: dict[str, Any], key: str) -> set[str]:
    metadata = catalog.get(f"@{key}", {})
    if metadata is None:
        return set()
    if not isinstance(metadata, dict):
        fail(f"metadata @{key} must be an object")
    placeholders = metadata.get("placeholders", {})
    if placeholders is None:
        return set()
    if not isinstance(placeholders, dict):
        fail(f"metadata @{key}.placeholders must be an object")
    return set(placeholders)


def validate_metadata(catalog: dict[str, Any], locale: str) -> None:
    keys = message_keys(catalog)
    for metadata_key in catalog:
        if not metadata_key.startswith("@") or metadata_key.startswith("@@"):
            continue
        message_key = metadata_key[1:]
        if message_key not in keys:
            fail(f"{locale}: metadata exists without message: {metadata_key}")


def main() -> int:
    catalogs = {
        locale: load_catalog(locale, path)
        for locale, path in CATALOGS.items()
    }
    for locale, catalog in catalogs.items():
        validate_metadata(catalog, locale)

    reference_locale = "en"
    reference = catalogs[reference_locale]
    reference_keys = message_keys(reference)

    for locale, catalog in catalogs.items():
        keys = message_keys(catalog)
        missing = sorted(reference_keys - keys)
        extra = sorted(keys - reference_keys)
        if missing:
            fail(f"{locale}: missing messages: {', '.join(missing)}")
        if extra:
            fail(f"{locale}: extra messages: {', '.join(extra)}")

        for key in sorted(reference_keys):
            reference_placeholders = placeholder_names(reference, key)
            locale_placeholders = placeholder_names(catalog, key)
            if reference_placeholders != locale_placeholders:
                fail(
                    f"{locale}: placeholder mismatch for {key}: "
                    f"expected {sorted(reference_placeholders)}, "
                    f"found {sorted(locale_placeholders)}"
                )

    print(
        f"localization catalogs valid: {len(reference_keys)} messages, "
        f"locales={','.join(sorted(catalogs))}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
