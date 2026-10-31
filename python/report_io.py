"""Tien ich chung: doi kieu sang JSON an toan, ghi file nguyen tu (atomic), kiem tra JSON Schema."""
from __future__ import annotations

import json
import math
import os
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

SCHEMAS_DIR = Path(__file__).resolve().parent.parent / "schemas"


class ReportError(Exception):
    """Loi ghi / kiem tra bao cao."""


def to_jsonable(value: Any) -> Any:
    """None/bool/int/float huu han giu nguyen; date/datetime -> ISO; Decimal va kieu khac -> str."""
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if type(value).__module__ == "numpy" and hasattr(value, "item"):
        value = value.item()
        if value is None or isinstance(value, (bool, int, str)):
            return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, (datetime, date)) or hasattr(value, "isoformat"):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    return str(value)


def validate_report(report: Any, schema_name: str, schemas_dir: Path = SCHEMAS_DIR) -> list[str]:
    """Tra ve danh sach loi (rong = hop le). Nem ReportError neu schema khong doc duoc."""
    path = Path(schemas_dir) / schema_name
    try:
        with path.open("r", encoding="utf-8") as fh:
            schema = json.load(fh)
        Draft202012Validator.check_schema(schema)
    except (OSError, json.JSONDecodeError) as exc:
        raise ReportError(f"Khong doc duoc schema {path}: {exc}") from exc
    except Exception as exc:  # SchemaError
        raise ReportError(f"Schema {path} khong hop le: {exc}") from exc
    errors = sorted(Draft202012Validator(schema).iter_errors(report), key=lambda e: list(map(str, e.path)))
    return [f"{'/'.join(map(str, e.path)) or '(goc)'}: {e.message}" for e in errors]


def atomic_write_json(path: Path | str, obj: Any) -> None:
    """Ghi vao file tam roi os.replace -> khong bao gio de lai file JSON do dang."""
    target = Path(path)
    tmp = target.with_name(target.name + ".tmp")
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps(obj, indent=2, ensure_ascii=False, allow_nan=False)
        with tmp.open("w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
            fh.write("\n")
        os.replace(tmp, target)
    except (OSError, TypeError, ValueError) as exc:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise ReportError(f"Khong ghi duoc {target}: {exc}") from exc
