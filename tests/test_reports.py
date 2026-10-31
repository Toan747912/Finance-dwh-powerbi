"""TC-DQ-05 (dq_report.json theo Schema 3) va xuat etl_log.json (Schema 2), dung sqlite3 lam DB gia."""
import json
import math
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))

import export_etl_log  # noqa: E402
import profiling  # noqa: E402
import report_io  # noqa: E402
from db import DbError, build_connection_string  # noqa: E402

sqlite3.register_adapter(datetime, lambda d: d.isoformat(" "))
sqlite3.register_converter("TIMESTAMP", lambda b: datetime.fromisoformat(b.decode()))

CONFIG = {"server": "localhost", "database_source": "AdventureWorks2022", "database_dw": "FinanceDW",
          "auth_mode": "windows", "batch_size": 1000}
T0 = datetime(2026, 1, 1, 10, 0, 0)


@pytest.fixture()
def conn():
    c = sqlite3.connect(":memory:", detect_types=sqlite3.PARSE_DECLTYPES)
    c.execute("ATTACH DATABASE ':memory:' AS dwh")
    c.execute("ATTACH DATABASE ':memory:' AS ops")
    c.execute("CREATE TABLE dwh.fact_sales (id INTEGER, qty INTEGER, note TEXT, amt REAL)")
    c.execute("CREATE TABLE ops.etl_log (log_id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, step TEXT, "
              "start_time TIMESTAMP, end_time TIMESTAMP, rows_read INTEGER, rows_loaded INTEGER, rows_rejected INTEGER, "
              "status TEXT, error_number INTEGER, error_message TEXT)")
    c.execute("CREATE TABLE ops.reject (reject_id INTEGER PRIMARY KEY, run_id TEXT, step TEXT, reason TEXT)")
    yield c
    c.close()


def add_log(c, run, step, sec, status="SUCCESS", errno=None, msg=None, loaded=1):
    c.execute("INSERT INTO ops.etl_log (run_id, step, start_time, end_time, rows_read, rows_loaded, rows_rejected, "
              "status, error_number, error_message) VALUES (?,?,?,?,?,?,?,?,?,?)",
              (run, step, T0 + timedelta(seconds=sec), T0 + timedelta(seconds=sec + 1), loaded, loaded, 0, status, errno, msg))


# ----------------------------- profiling -----------------------------
@pytest.mark.parametrize("batch", [1, 2, 100])
def test_profile_stats_independent_of_batch(conn, batch):
    conn.executemany("INSERT INTO dwh.fact_sales VALUES (?,?,?,?)",
                     [(1, 10, "a", 1.5), (2, None, "a", 2.5), (3, 30, None, None), (4, 10, "b", 4.0)])
    t = profiling.profile_table(conn, "dwh", "fact_sales", batch)
    cols = {c["name"]: c for c in t["columns"]}
    assert t["row_count"] == 4
    assert cols["qty"]["null_count"] == 1 and cols["qty"]["null_pct"] == 25.0
    assert cols["qty"]["distinct_count"] == 2 and cols["qty"]["min"] == 10 and cols["qty"]["max"] == 30
    assert cols["note"]["distinct_count"] == 2 and cols["note"]["min"] == "a" and cols["note"]["max"] == "b"
    assert cols["amt"]["min"] == 1.5 and cols["amt"]["max"] == 4.0 and cols["amt"]["null_count"] == 1


def test_profile_empty_table(conn):
    t = profiling.profile_table(conn, "dwh", "fact_sales", 100)
    assert t["row_count"] == 0
    assert all(c["null_pct"] is None and c["min"] is None and c["distinct_count"] == 0 for c in t["columns"])


def test_profile_all_null_column(conn):
    conn.executemany("INSERT INTO dwh.fact_sales (id) VALUES (?)", [(1,), (2,)])
    cols = {c["name"]: c for c in profiling.profile_table(conn, "dwh", "fact_sales", 10)["columns"]}
    assert cols["note"]["null_pct"] == 100.0 and cols["note"]["min"] is None


@pytest.mark.parametrize("batch", [1, 10])
def test_profile_mixed_types_do_not_crash(conn, batch):
    conn.executemany("INSERT INTO dwh.fact_sales (id) VALUES (?)", [("x",), (5,)])   # cot INTEGER nhan ca chuoi
    col = profiling.profile_table(conn, "dwh", "fact_sales", batch)["columns"][0]
    assert col["min"] is None and col["max"] is None and col["distinct_count"] == 2


def test_profile_keeps_big_int_exact(conn):
    big = 2**60 + 1
    conn.executemany("INSERT INTO dwh.fact_sales (id, qty) VALUES (?,?)", [(1, big), (2, None)])
    qty = {c["name"]: c for c in profiling.profile_table(conn, "dwh", "fact_sales", 1)["columns"]}["qty"]
    assert qty["max"] == big and qty["null_count"] == 1


def test_profile_distinct_cap(conn, monkeypatch):
    monkeypatch.setattr(profiling, "DISTINCT_CAP", 2)
    conn.executemany("INSERT INTO dwh.fact_sales (id) VALUES (?)", [(i,) for i in range(5)])
    idc = profiling.profile_table(conn, "dwh", "fact_sales", 2)["columns"][0]
    assert idc["distinct_capped"] is True and idc["distinct_count"] is None


@pytest.mark.parametrize("schema,table", [("dwh; DROP TABLE x", "t"), ("dwh", "t]--"), ("", "t"), ("dwh", "")])
def test_profile_rejects_bad_identifier(conn, schema, table):
    with pytest.raises(profiling.QueryError):
        profiling.profile_table(conn, schema, table, 10)


@pytest.mark.parametrize("batch", [0, -1, True, "5", 1.5])
def test_profile_rejects_bad_batch(conn, batch):
    with pytest.raises(profiling.QueryError):
        profiling.profile_table(conn, "dwh", "fact_sales", batch)


def test_profile_missing_table(conn):
    with pytest.raises(profiling.QueryError, match="fact_nope"):
        profiling.profile_table(conn, "dwh", "fact_nope", 10)


def test_report_matches_schema3_and_latest_reject_only(conn):
    conn.executemany("INSERT INTO dwh.fact_sales VALUES (?,?,?,?)", [(1, 1, "a", 1.0), (2, 2, "b", 2.0)])
    add_log(conn, "old", "dwh.fact_sales", 0)
    add_log(conn, "new", "dwh.fact_sales", 10)
    conn.executemany("INSERT INTO ops.reject (run_id, step, reason) VALUES (?,?,?)",
                     [("old", "dwh.fact_sales", "ORPHAN_HEADER"), ("new", "dwh.fact_sales", "DATE_NOT_FOUND"),
                      ("new", "dwh.fact_sales", "DATE_NOT_FOUND")])
    rep = profiling.build_report(conn, CONFIG, tables=[("dwh", "fact_sales")], now=T0.replace(tzinfo=timezone.utc))
    assert report_io.validate_report(rep, profiling.SCHEMA_NAME) == []
    assert rep["rejects"] == [{"step": "dwh.fact_sales", "reason": "DATE_NOT_FOUND", "count": 2}]
    assert rep["summary"] == {"table_count": 1, "total_rows": 2, "columns_with_nulls": 0}


def test_report_json_roundtrip_has_no_nan(conn):
    conn.execute("INSERT INTO dwh.fact_sales VALUES (1, 1, 'a', NULL)")
    rep = profiling.build_report(conn, CONFIG, tables=[("dwh", "fact_sales")], now=T0.replace(tzinfo=timezone.utc))
    json.dumps(rep, allow_nan=False)


@pytest.mark.parametrize("mutate", [
    lambda r: r.pop("rejects"),
    lambda r: r.__setitem__("schema_version", 2),
    lambda r: r["tables"][0]["columns"][0].__setitem__("null_pct", 101),
    lambda r: r["tables"][0].__setitem__("row_count", -1),
    lambda r: r.__setitem__("extra", 1),
])
def test_schema3_rejects_bad_report(conn, mutate):
    rep = profiling.build_report(conn, CONFIG, tables=[("dwh", "fact_sales")], now=T0.replace(tzinfo=timezone.utc))
    mutate(rep)
    assert report_io.validate_report(rep, profiling.SCHEMA_NAME) != []


# ----------------------------- run() / ma thoat -----------------------------
def write_cfg(tmp_path, cfg=CONFIG):
    p = tmp_path / "config.json"
    p.write_text(json.dumps(cfg), encoding="utf-8")
    return p


def test_profiling_run_ok_writes_valid_file(conn, tmp_path, monkeypatch):
    monkeypatch.setattr(profiling, "discover_tables", lambda c, schema="dwh": [("dwh", "fact_sales")])
    out = tmp_path / "sub" / "dq.json"
    assert profiling.run(write_cfg(tmp_path), out, conn_factory=lambda cfg: conn) == 0
    assert report_io.validate_report(json.loads(out.read_text(encoding="utf-8")), profiling.SCHEMA_NAME) == []
    assert not list(out.parent.glob("*.tmp"))


def test_profiling_run_missing_config(tmp_path):
    assert profiling.run(tmp_path / "none.json", tmp_path / "o.json", conn_factory=lambda c: None) == 1


def test_profiling_run_bad_config(tmp_path):
    assert profiling.run(write_cfg(tmp_path, {**CONFIG, "batch_size": 5}), tmp_path / "o.json", conn_factory=lambda c: None) == 1


def test_profiling_run_connect_fail(tmp_path):
    def boom(cfg):
        raise DbError("down")
    out = tmp_path / "o.json"
    assert profiling.run(write_cfg(tmp_path), out, conn_factory=boom) == 2
    assert not out.exists()


def test_profiling_run_query_fail_leaves_old_file(conn, tmp_path, monkeypatch):
    monkeypatch.setattr(profiling, "discover_tables", lambda c, schema="dwh": [("dwh", "fact_nope")])
    out = tmp_path / "o.json"
    out.write_text("OLD", encoding="utf-8")
    assert profiling.run(write_cfg(tmp_path), out, conn_factory=lambda cfg: conn) == 3
    assert out.read_text(encoding="utf-8") == "OLD"


def test_profiling_run_schema_violation_not_written(conn, tmp_path, monkeypatch):
    monkeypatch.setattr(profiling, "build_report", lambda c, cfg: {"schema_version": 1})
    out = tmp_path / "o.json"
    assert profiling.run(write_cfg(tmp_path), out, conn_factory=lambda cfg: conn) == 4
    assert not out.exists()


# ----------------------------- etl_log export -----------------------------
def test_etl_log_groups_runs_newest_first(conn):
    add_log(conn, "r1", "stg.A", 0)
    add_log(conn, "r1", "stg.B", 1)
    add_log(conn, "r2", "dwh.dim_date", 100)
    add_log(conn, "r2", "dwh.dim_product", 101, status="ROLLED_BACK")
    add_log(conn, "r3", "pipeline", 200, status="FAILED", errno=50070, msg="Giai doan stg: loi")
    runs = export_etl_log.fetch_runs(conn, 2)
    assert [r["run_id"] for r in runs] == ["r3", "r2"]
    assert runs[0]["status"] == "FAILED" and runs[1]["status"] == "ROLLED_BACK"
    assert runs[1]["duration_sec"] == 2.0 and len(runs[1]["steps"]) == 2
    assert [r["run_id"] for r in export_etl_log.fetch_runs(conn, 10)] == ["r3", "r2", "r1"]
    assert export_etl_log.fetch_runs(conn, 10)[2]["status"] == "SUCCESS"


def test_etl_log_empty_exports_valid_file(conn, tmp_path):
    out = tmp_path / "e.json"
    assert export_etl_log.run(write_cfg(tmp_path), out, 5, conn_factory=lambda c: conn) == 0
    data = json.loads(out.read_text(encoding="utf-8"))
    assert data["runs"] == [] and report_io.validate_report(data, export_etl_log.SCHEMA_NAME) == []


def test_etl_log_run_ok_valid_schema2(conn, tmp_path):
    add_log(conn, "r1", "pipeline", 0)
    out = tmp_path / "e.json"
    assert export_etl_log.run(write_cfg(tmp_path), out, 5, conn_factory=lambda c: conn) == 0
    assert report_io.validate_report(json.loads(out.read_text(encoding="utf-8")), export_etl_log.SCHEMA_NAME) == []


@pytest.mark.parametrize("runs", [0, -3, 1001, True, "5"])
def test_etl_log_bad_runs(conn, runs):
    with pytest.raises(export_etl_log.QueryError):
        export_etl_log.fetch_runs(conn, runs)


def test_etl_log_missing_table_exit3(tmp_path):
    empty = sqlite3.connect(":memory:")
    assert export_etl_log.run(write_cfg(tmp_path), tmp_path / "e.json", 5, conn_factory=lambda c: empty) == 3


def test_schema2_failed_requires_message():
    rep = {"schema_version": 1, "generated_at": "2026-01-01T00:00:00+00:00", "database": "FinanceDW", "runs": [{
        "run_id": "r", "status": "FAILED", "start_time": "2026-01-01T00:00:00", "end_time": "2026-01-01T00:00:01",
        "duration_sec": 1, "steps": [{"step": "s", "start_time": "2026-01-01T00:00:00", "end_time": "2026-01-01T00:00:01",
                                      "rows_read": 0, "rows_loaded": 0, "rows_rejected": 0, "status": "FAILED",
                                      "error_number": 1, "error_message": None}]}]}
    assert report_io.validate_report(rep, export_etl_log.SCHEMA_NAME) != []
    rep["runs"][0]["steps"][0]["error_message"] = "x"
    assert report_io.validate_report(rep, export_etl_log.SCHEMA_NAME) == []


# ----------------------------- tien ich -----------------------------
def test_to_jsonable():
    assert report_io.to_jsonable(Decimal("1.50")) == "1.50"
    assert report_io.to_jsonable(float("nan")) is None and report_io.to_jsonable(math.inf) is None
    assert report_io.to_jsonable(T0) == "2026-01-01T10:00:00"
    assert report_io.to_jsonable(b"x") == "b'x'" and report_io.to_jsonable(True) is True


def test_atomic_write_failure_keeps_old(tmp_path):
    p = tmp_path / "x.json"
    p.write_text("OLD", encoding="utf-8")
    with pytest.raises(report_io.ReportError):
        report_io.atomic_write_json(p, {"a": float("nan")})
    assert p.read_text(encoding="utf-8") == "OLD" and not list(tmp_path.glob("*.tmp"))


def test_validate_report_missing_schema(tmp_path):
    with pytest.raises(report_io.ReportError):
        report_io.validate_report({}, "nope.json", schemas_dir=tmp_path)


def test_connection_string():
    assert "Trusted_Connection=yes" in build_connection_string(CONFIG, env={})
    sql_cfg = {**CONFIG, "auth_mode": "sql"}
    with pytest.raises(DbError):
        build_connection_string(sql_cfg, env={})
    s = build_connection_string(sql_cfg, env={"DW_USER": "u", "DW_PASSWORD": "p", "DW_ODBC_DRIVER": "D"})
    assert "UID=u" in s and "DRIVER={D}" in s and "Trusted_Connection" not in s
