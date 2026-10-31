"""TC-ENV-04: kiem tra validate config.json theo config.schema.json."""
import copy
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))

from validate_config import ConfigError, main, validate_config  # noqa: E402

VALID = {
    "server": "localhost",
    "database_source": "AdventureWorks2022",
    "database_dw": "FinanceDW",
    "auth_mode": "windows",
    "batch_size": 50000,
}


def write(tmp_path, data, name="config.json"):
    p = tmp_path / name
    p.write_text(data if isinstance(data, str) else json.dumps(data), encoding="utf-8")
    return p


def test_example_file_is_valid():
    assert validate_config(ROOT / "config.example.json") == []


def test_valid_config_passes(tmp_path):
    assert validate_config(write(tmp_path, VALID)) == []


@pytest.mark.parametrize("field", list(VALID))
def test_missing_field_is_reported_by_name(tmp_path, field):
    cfg = copy.deepcopy(VALID)
    del cfg[field]
    errors = validate_config(write(tmp_path, cfg))
    assert errors and any(field in e for e in errors)


@pytest.mark.parametrize("size", [10, 999, 500001])
def test_batch_size_out_of_range(tmp_path, size):
    errors = validate_config(write(tmp_path, {**VALID, "batch_size": size}))
    assert errors and any("batch_size" in e for e in errors)


def test_batch_size_wrong_type(tmp_path):
    errors = validate_config(write(tmp_path, {**VALID, "batch_size": "50000"}))
    assert errors and any("batch_size" in e for e in errors)


@pytest.mark.parametrize("bad", ["", "Fin ance", "dw;DROP", "dw-1"])
def test_database_dw_pattern(tmp_path, bad):
    errors = validate_config(write(tmp_path, {**VALID, "database_dw": bad}))
    assert errors and any("database_dw" in e for e in errors)


def test_wrong_source_database(tmp_path):
    errors = validate_config(write(tmp_path, {**VALID, "database_source": "AdventureWorks2019"}))
    assert errors and any("database_source" in e for e in errors)


def test_invalid_auth_mode(tmp_path):
    errors = validate_config(write(tmp_path, {**VALID, "auth_mode": "kerberos"}))
    assert errors and any("auth_mode" in e for e in errors)


def test_extra_property_rejected_so_no_password_in_config(tmp_path):
    errors = validate_config(write(tmp_path, {**VALID, "password": "secret"}))
    assert errors and any("password" in e for e in errors)


def test_all_errors_reported_not_just_first(tmp_path):
    errors = validate_config(write(tmp_path, {"server": "", "batch_size": 10}))
    joined = " ".join(errors)
    for token in ("server", "batch_size", "database_dw", "auth_mode", "database_source"):
        assert token in joined


def test_missing_file_raises_config_error(tmp_path):
    with pytest.raises(ConfigError):
        validate_config(tmp_path / "nope.json")


def test_malformed_json_raises_config_error(tmp_path):
    with pytest.raises(ConfigError):
        validate_config(write(tmp_path, "{not json"))


def test_cli_exit_codes(tmp_path):
    assert main(["x", str(write(tmp_path, VALID))]) == 0
    assert main(["x", str(write(tmp_path, {**VALID, "batch_size": 10}, "bad.json"))]) == 1
    assert main(["x", str(tmp_path / "missing.json")]) == 2
