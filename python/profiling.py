#!/usr/bin/env python3
"""Profiling chat luong du lieu DW -> dq_report.json (Schema 3).

Cach dung:  python python/profiling.py [--config config.json] [--out output/dq_report.json]
Ma thoat:   0 OK | 1 config sai | 2 khong ket noi / thieu thu vien | 3 loi truy van | 4 loi ghi / sai schema
Doc bang tung lo (fetchmany = batch_size) bang pandas -> khong nap ca bang vao RAM.
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pandas as pd

from db import DbError, connect, load_config
from report_io import ReportError, atomic_write_json, to_jsonable, validate_report
from validate_config import ConfigError

IDENT = re.compile(r"^[A-Za-z0-9_]+$")
DISTINCT_CAP = 1_000_000      # vuot nguong nay thi ngung dem distinct (distinct_capped = true)
DEFAULT_OUT = Path("output") / "dq_report.json"
SCHEMA_NAME = "dq_report.schema.json"

DISCOVER_SQL = (
    "SELECT s.name, t.name FROM sys.tables AS t JOIN sys.schemas AS s ON s.schema_id = t.schema_id "
    "WHERE s.name = ? ORDER BY t.name"
)
REJECT_SQL = (
    "SELECT r.step, r.reason, COUNT(*) FROM ops.reject AS r "
    "WHERE r.run_id = (SELECT l2.run_id FROM ops.etl_log AS l2 WHERE l2.log_id = "
    "(SELECT MAX(l.log_id) FROM ops.etl_log AS l WHERE l.step = r.step AND l.status = 'SUCCESS')) "
    "GROUP BY r.step, r.reason ORDER BY r.step, r.reason"
)


class QueryError(Exception):
    """Loi khi truy van co so du lieu."""


def _check_ident(name: str) -> str:
    if not isinstance(name, str) or not IDENT.match(name):
        raise QueryError(f"Ten doi tuong khong hop le: {name!r}")
    return name


def discover_tables(conn, schema: str = "dwh") -> list[tuple[str, str]]:
    _check_ident(schema)
    try:
        cur = conn.cursor()
        cur.execute(DISCOVER_SQL, (schema,))
        return [(str(a), str(b)) for a, b in cur.fetchall()]
    except Exception as exc:
        raise QueryError(f"Khong liet ke duoc bang cua schema {schema}: {exc}") from exc


class _ColStat:
    __slots__ = ("name", "dtype", "nulls", "distinct", "capped", "min", "max", "minmax_ok")

    def __init__(self, name: str, dtype: str):
        self.name, self.dtype = name, dtype
        self.nulls = 0
        self.distinct: set = set()
        self.capped = False
        self.min = self.max = None
        self.minmax_ok = True

    def update(self, series: pd.Series) -> None:
        self.nulls += int(series.isna().sum())
        values = series.dropna()
        if values.empty:
            return
        if not self.capped:
            try:
                self.distinct.update(values.tolist())
            except TypeError:                      # gia tri khong hash duoc
                self.distinct.update(str(v) for v in values.tolist())
            if len(self.distinct) > DISTINCT_CAP:
                self.capped = True
                self.distinct = set()
        if self.minmax_ok:
            try:
                lo, hi = values.min(), values.max()
                self.min = lo if self.min is None or lo < self.min else self.min
                self.max = hi if self.max is None or hi > self.max else self.max
            except TypeError:                      # kieu hon hop khong so sanh duoc
                self.minmax_ok = False
                self.min = self.max = None

    def to_dict(self, total: int) -> dict[str, Any]:
        return {
            "name": self.name,
            "dtype": self.dtype,
            "null_count": self.nulls,
            "null_pct": round(100.0 * self.nulls / total, 4) if total else None,
            "distinct_count": None if self.capped else len(self.distinct),
            "distinct_capped": self.capped,
            "min": to_jsonable(self.min) if self.minmax_ok else None,
            "max": to_jsonable(self.max) if self.minmax_ok else None,
        }


def profile_table(conn, schema: str, table: str, batch_size: int) -> dict[str, Any]:
    """Profile 1 bang theo tung lo batch_size dong."""
    _check_ident(schema)
    _check_ident(table)
    if not isinstance(batch_size, int) or isinstance(batch_size, bool) or batch_size < 1:
        raise QueryError(f"batch_size phai la so nguyen duong, nhan {batch_size!r}")
    try:
        cur = conn.cursor()
        cur.execute(f"SELECT * FROM [{schema}].[{table}]")
        if cur.description is None:
            raise QueryError("cau lenh khong tra ve tap ket qua")
        cols = [d[0] for d in cur.description]
        stats = [
            _ColStat(d[0], d[1].__name__ if isinstance(d[1], type) else str(d[1]))
            for d in cur.description
        ]
        total = 0
        while True:
            rows = cur.fetchmany(batch_size)
            if not rows:
                break
            # dtype=object: giu nguyen kieu Python (khong ep INT co NULL thanh float, khong mat chinh xac Decimal)
            df = pd.DataFrame([tuple(r) for r in rows], columns=cols, dtype=object)
            total += len(df)
            for i, st in enumerate(stats):
                st.update(df.iloc[:, i])
    except QueryError:
        raise
    except Exception as exc:
        raise QueryError(f"Loi khi profile {schema}.{table}: {exc}") from exc
    return {"schema": schema, "table": table, "row_count": total, "columns": [s.to_dict(total) for s in stats]}


def fetch_rejects(conn) -> list[dict[str, Any]]:
    try:
        cur = conn.cursor()
        cur.execute(REJECT_SQL)
        return [{"step": str(s), "reason": str(r), "count": int(c)} for s, r, c in cur.fetchall()]
    except Exception as exc:
        raise QueryError(f"Khong doc duoc ops.reject: {exc}") from exc


def build_report(conn, config: dict[str, Any], schema: str = "dwh",
                 tables: list[tuple[str, str]] | None = None, now: datetime | None = None) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc)
    if tables is None:
        tables = discover_tables(conn, schema)
    profiled = [profile_table(conn, s, t, config["batch_size"]) for s, t in tables]
    return {
        "schema_version": 1,
        "generated_at": now.replace(microsecond=0).isoformat(),
        "database": config["database_dw"],
        "batch_size": config["batch_size"],
        "summary": {
            "table_count": len(profiled),
            "total_rows": sum(t["row_count"] for t in profiled),
            "columns_with_nulls": sum(1 for t in profiled for c in t["columns"] if c["null_count"] > 0),
        },
        "tables": profiled,
        "rejects": fetch_rejects(conn),
    }


def run(config_path: Path, out_path: Path, conn_factory=connect) -> int:
    try:
        config = load_config(config_path)
    except ConfigError as exc:
        print(f"LOI config: {exc}", file=sys.stderr)
        return 1
    try:
        conn = conn_factory(config)
    except DbError as exc:
        print(f"LOI ket noi: {exc}", file=sys.stderr)
        return 2
    try:
        report = build_report(conn, config)
    except QueryError as exc:
        print(f"LOI truy van: {exc}", file=sys.stderr)
        return 3
    finally:
        try:
            conn.close()
        except Exception:
            pass
    try:
        problems = validate_report(report, SCHEMA_NAME)
        if problems:
            print("LOI: bao cao sai Schema 3 (khong ghi file):", file=sys.stderr)
            for p in problems:
                print(f"  - {p}", file=sys.stderr)
            return 4
        atomic_write_json(out_path, report)
    except ReportError as exc:
        print(f"LOI ghi bao cao: {exc}", file=sys.stderr)
        return 4
    print(f"OK: {out_path} ({report['summary']['table_count']} bang, {report['summary']['total_rows']} dong)")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Profiling DW -> dq_report.json")
    ap.add_argument("--config", type=Path, default=Path("config.json"))
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args(argv[1:])
    return run(args.config, args.out)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
