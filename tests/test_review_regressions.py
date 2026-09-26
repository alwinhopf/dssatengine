"""Offline regressions for run alignment and failed rerun publication."""
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from dssatengine import engine


@pytest.mark.parametrize("runs,values", [
    ([2, 2, 1, 1], [200, 210, 100, 110]),
    ([2, 1, 2, 1], [200, 100, 210, 110]),
    ([2, 1, 2, 1], [np.nan, 100, 210, np.nan]),
])
def test_soil_endpoints_keep_run_keys_and_missing_values(monkeypatch, runs, values):
    soil = pd.DataFrame({"RUN": runs, "SOMCT": values})
    monkeypatch.setattr(engine, "_read_csv_safe",
                        lambda p: soil if Path(p).name == "soilorg.csv" else None)
    result = engine._merge_supplemental("unused", pd.DataFrame({"RUNNO": [1, 2]}))
    for run in [1, 2]:
        expected = soil.loc[soil.RUN == run, "SOMCT"]
        actual = result.loc[result.RUNNO == run].iloc[0]
        np.testing.assert_equal(actual.SOMCT_start, expected.iloc[0])
        np.testing.assert_equal(actual.SOMCT_end, expected.iloc[-1])


@pytest.mark.parametrize("failure", ["setup", "run", "write"])
@pytest.mark.parametrize("mode", ["experiment", "sequence"])
def test_failed_rerun_never_leaves_completion_file(tmp_path, monkeypatch, failure, mode):
    point = tmp_path / "p1"
    point.mkdir()
    result_path = point / "results_p1.csv"
    result_path.write_text("stale result")
    template = point / "p1.MZX"
    template.write_text("*EXP.DETAILS\n")

    def fail(*args, **kwargs):
        raise RuntimeError("injected failure")

    if failure == "setup":
        monkeypatch.setattr(engine, "_resolve_point_filex", fail)
    monkeypatch.setattr(engine, "run_dssat", fail if failure == "run" else lambda *a, **k: None)
    monkeypatch.setattr(engine, "_read_csv_safe", lambda p: pd.DataFrame({"RUNNO": [1], "PDAT": [2001001]}))
    monkeypatch.setattr(engine, "_merge_supplemental", lambda p, r: r)
    monkeypatch.setattr(engine, "_build_result_rows", lambda *a, **k: pd.DataFrame({"point_id": ["p1"]}))
    if failure == "write":
        def failed_write(self, path, **kwargs):
            Path(path).write_text("partial")
            fail()
        monkeypatch.setattr(pd.DataFrame, "to_csv", failed_write)
    with pytest.raises(RuntimeError, match="injected failure"):
        engine._run_simulation("p1", pd.Series({"LAT": 1, "LONG": 2}), str(tmp_path),
                               "MZ", template.name, str(template), mode,
                               1, 1, 1, 1, 2001, 2001, "fake")
    assert not result_path.exists()
    assert not list(point.glob(".results-*"))


def test_stale_raw_output_cleanup_failure_stops_execution(tmp_path, monkeypatch):
    point = tmp_path / "p1"
    point.mkdir()
    template = point / "p1.MZX"
    template.write_text("*EXP.DETAILS\n")
    (point / "summary.csv").write_text("stale")
    calls = []
    monkeypatch.setattr(engine, "run_dssat", lambda *a, **k: calls.append(1))
    monkeypatch.setattr(engine.os, "remove", lambda p: (_ for _ in ()).throw(PermissionError("locked")))
    with pytest.raises(PermissionError, match="locked"):
        engine._run_simulation("p1", pd.Series(), str(tmp_path), "MZ", template.name,
                               str(template), "experiment", 1, 1, 1, 1, 2001, 2001, "fake")
    assert not calls


def test_read_csv_safe_preserves_text_cols_and_handles_overflow(tmp_path):
    p = tmp_path / "summary.csv"
    p.write_text("RUNNO,SOIL_ID,TNAM,CWAM,OVERFLOW\n1,000123,10,150.0,*****\n2,000124,20,-99.0,*****\n")
    df = engine._read_csv_safe(str(p))
    assert df is not None
    assert list(df["RUNNO"]) == [1, 2]
    assert list(df["SOIL_ID"]) == ["000123", "000124"]
    assert list(df["TNAM"]) == ["10", "20"]
    assert df["CWAM"].iloc[0] == 150.0
    assert pd.isna(df["CWAM"].iloc[1])
    assert pd.api.types.is_float_dtype(df["OVERFLOW"])
    assert df["OVERFLOW"].isna().all()


def test_build_result_rows_schema_complete():
    summary = pd.DataFrame({
        "RUNNO": [1], "TRNO": [1], "CR": ["MZ"], "LAT": [10.0], "LONG": [20.0],
        "WSTA": ["W01"], "SOIL_ID": ["S01"], "EXNAME": ["EX01"], "TNAM": ["TRT1"],
        "PDAT": [2001001], "EDAT": [2001005], "ADAT": [2001050], "MDAT": [2001090],
        "HDAT": [2001100], "PYEAR": ["2001"], "HYEAR": [2001], "CWAM": [1000],
        "HWAM": [500], "PWAM": [200], "HWUM": [0.3], "HIAM": [0.5], "LAIX": [3.5],
        "BWAH": [100], "CO2EM": [120], "N2OEM": [2],
    })
    mr = pd.DataFrame({
        "RUNNO": [1], "SOMCT_start": [100.0], "SOMCT_end": [110.0],
        "IRC": [2], "IRRC": [50.0], "NIM": [3], "NAPC": [80.0], "NLCC": [15.0],
    })
    res = engine._build_result_rows("p1", summary, mr)
    assert len(res.columns) == 38
    assert res.loc[0, "point_id"] == "p1"
    assert res.loc[0, "soil_organic_carbon_delta_kg_C_ha"] == 10.0
    assert res.loc[0, "cumulative_net_co2_emissions_kg_CO2_ha"] == 120 * (44.0 / 12.0)
    assert res.loc[0, "output_metric_schema"] == 2
