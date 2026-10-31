#!/usr/bin/env python3
"""Xuat ops.etl_log -> etl_log.json (Schema 2), gom theo run_id, N lan chay gan nhat.

Cach dung:  python python/export_etl_log.py [--config config.json] [--out output/etl_log.json] [--runs 5]
Ma thoat:   0 OK | 1 config sai | 2 khong ket noi | 3 loi truy van | 4 loi ghi / sai schema
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from db import DbError, connect, load_config
from report_io import ReportError, atomic_write_json, to_jsonable, validate_report
from validate_config import ConfigError

DEFAULT_OUT = Path("output") / "etl_log.json"
SCHEMA_NAME = "etl_log.schema.json"
MAX_RUNS = 1000
COLS = "log_id, run_id, step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message"


class QueryError(Exception):
    """Loi khi truy van co so du lieu."""


def _iso(v: Any) -> str:
    out = to_jsonable(v)
    return out if isinstance(out, str) else str(out)


def _overall(statuses: list[str]) -> str:
    if "FAILED" in statuses:
        return "FAILED"
    if "ROLLED_BACK" in statuses:
        return "ROLLED_BACK"
    return "SUCCESS"


def fetch_runs(conn, runs: int) -> list[dict[str, Any]]:
    if not isinstance(runs, int) or isinstance(runs, bool) or not 1 <= runs <= MAX_RUNS:
        raise QueryError(f"--runs phai trong khoang 1..{MAX_RUNS}, nhan {runs!r}")
    try:
        cur = conn.cursor()
        cur.execute("SELECT run_id, MIN(log_id) AS first_id FROM ops.etl_log GROUP BY run_id ORDER BY first_id DESC")
        run_ids = [str(r[0]) for r in cur.fetchmany(runs)]
        if not run_ids:
            return []
        marks = ", ".join("?" for _ in run_ids)
        cur.execute(f"SELECT {COLS} FROM ops.etl_log WHERE run_id IN ({marks}) ORDER BY log_id", tuple(run_ids))
        rows = cur.fetchall()
    except Exception as exc:
        raise QueryError(f"Khong doc duoc ops.etl_log: {exc}") from exc

    grouped: dict[str, list[tuple]] = {}
    for r in rows:
        grouped.setdefault(str(r[1]), []).append(tuple(r))

    result = []
    for rid in run_ids:                                    # moi nhat truoc
        steps_raw = grouped.get(rid, [])
        if not steps_raw:
            continue
        steps = [{
            "step": str(r[2]), "start_time": _iso(r[3]), "end_time": _iso(r[4]),
            "rows_read": int(r[5]), "rows_loaded": int(r[6]), "rows_rejected": int(r[7]),
            "status": str(r[8]), "error_number": None if r[9] is None else int(r[9]),
            "error_message": None if r[10] is None else str(r[10]),
        } for r in steps_raw]
        starts = [r[3] for r in steps_raw]
        ends = [r[4] for r in steps_raw]
        try:
            duration = round((max(ends) - min(starts)).total_seconds(), 3)
        except (TypeError, AttributeError):
            duration = 0.0
        result.append({
            "run_id": rid, "status": _overall([s["status"] for s in steps]),
            "start_time": _iso(min(starts)), "end_time": _iso(max(ends)),
            "duration_sec": max(duration, 0.0), "steps": steps,
        })
    return result


def run(config_path: Path, out_path: Path, runs: int, conn_factory=connect) -> int:
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
        data = fetch_runs(conn, runs)
    except QueryError as exc:
        print(f"LOI truy van: {exc}", file=sys.stderr)
        return 3
    finally:
        try:
            conn.close()
        except Exception:
            pass
    report = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "database": config["database_dw"],
        "runs": data,
    }
    try:
        problems = validate_report(report, SCHEMA_NAME)
        if problems:
            print("LOI: bao cao sai Schema 2 (khong ghi file):", file=sys.stderr)
            for p in problems:
                print(f"  - {p}", file=sys.stderr)
            return 4
        atomic_write_json(out_path, report)
    except ReportError as exc:
        print(f"LOI ghi bao cao: {exc}", file=sys.stderr)
        return 4
    print(f"OK: {out_path} ({len(data)} lan chay)")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Xuat ops.etl_log -> etl_log.json")
    ap.add_argument("--config", type=Path, default=Path("config.json"))
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--runs", type=int, default=5)
    args = ap.parse_args(argv[1:])
    return run(args.config, args.out, args.runs)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
