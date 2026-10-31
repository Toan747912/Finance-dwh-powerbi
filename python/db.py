"""Ket noi SQL Server theo config.json. pyodbc chi import khi can (test dung ket noi gia)."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from validate_config import ConfigError, validate_config, _load_json

ODBC_DRIVER_ENV = "DW_ODBC_DRIVER"
DEFAULT_DRIVER = "ODBC Driver 18 for SQL Server"


class DbError(Exception):
    """Khong ket noi duoc co so du lieu hoac thieu thu vien / thong tin dang nhap."""


def load_config(path: Path | str) -> dict[str, Any]:
    """Doc va kiem tra config; nem ConfigError neu sai."""
    problems = validate_config(path)
    if problems:
        raise ConfigError("config khong hop le: " + "; ".join(problems))
    return _load_json(Path(path), "file cau hinh")


def build_connection_string(config: dict[str, Any], env: dict[str, str] | None = None) -> str:
    env = os.environ if env is None else env
    driver = env.get(ODBC_DRIVER_ENV, DEFAULT_DRIVER)
    parts = [
        f"DRIVER={{{driver}}}",
        f"SERVER={config['server']}",
        f"DATABASE={config['database_dw']}",
        "TrustServerCertificate=yes",
        "Encrypt=optional",
    ]
    if config["auth_mode"] == "windows":
        parts.append("Trusted_Connection=yes")
    else:
        user, pwd = env.get("DW_USER"), env.get("DW_PASSWORD")
        if not user or not pwd:
            raise DbError("auth_mode=sql can bien moi truong DW_USER va DW_PASSWORD (khong luu trong config).")
        parts += [f"UID={user}", f"PWD={pwd}"]
    return ";".join(parts)


def connect(config: dict[str, Any], timeout: int = 15):
    try:
        import pyodbc  # noqa: WPS433
    except ImportError as exc:
        raise DbError("Thieu thu vien pyodbc. Chay: pip install -r python/requirements.txt") from exc
    try:
        return pyodbc.connect(build_connection_string(config), timeout=timeout)
    except pyodbc.Error as exc:
        raise DbError(f"Khong ket noi duoc {config['server']}/{config['database_dw']}: {exc}") from exc
