#!/usr/bin/env python3
"""Kiem tra config.json theo config.schema.json (TC-ENV-04).

Cach dung:  python python/validate_config.py [duong_dan_config.json]
Ma thoat:   0 = hop le | 1 = sai schema | 2 = khong doc duoc file (thieu / JSON hong / schema hong)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "config.schema.json"
DEFAULT_CONFIG = Path("config.json")


class ConfigError(Exception):
    """Khong doc/parse duoc file cau hinh hoac schema."""


def _load_json(path: Path, label: str):
    try:
        with path.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError as exc:
        raise ConfigError(f"Khong tim thay {label}: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(
            f"{label} khong phai JSON hop le ({path}), dong {exc.lineno} cot {exc.colno}: {exc.msg}"
        ) from exc
    except OSError as exc:
        raise ConfigError(f"Khong doc duoc {label} ({path}): {exc}") from exc


def validate_config(config_path: Path | str, schema_path: Path | str = SCHEMA_PATH) -> list[str]:
    """Tra ve danh sach loi (rong = hop le). Nem ConfigError neu khong doc duoc file."""
    config = _load_json(Path(config_path), "file cau hinh")
    schema = _load_json(Path(schema_path), "schema")
    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as exc:
        raise ConfigError(f"Schema khong hop le: {exc.message}") from exc

    errors = sorted(Draft202012Validator(schema).iter_errors(config), key=lambda e: list(map(str, e.path)))
    return [f"{'/'.join(map(str, e.path)) or '(goc)'}: {e.message}" for e in errors]


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT_CONFIG
    try:
        problems = validate_config(path)
    except ConfigError as exc:
        print(f"LOI: {exc}", file=sys.stderr)
        return 2
    if problems:
        print(f"config khong hop le ({path}):", file=sys.stderr)
        for line in problems:
            print(f"  - {line}", file=sys.stderr)
        return 1
    print(f"OK: {path} hop le.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
