"""Tests for dssatengine.output_parser against real DSSAT output fixtures.

Fast and offline — no DSSAT binary needed. Fixtures in tests/fixtures/ are real
DSSAT 4.8 output files (a wheat run + a maize Summary.OUT) plus one synthetic
sequence-rotation PlantGro to exercise the multi-crop / multi-header path.
"""
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from dssatengine import (
    parse_timeseries, parse_plantgro, parse_summary, parse_evaluate,
    parse_csv, parse_dssat_output, read_run_directory, yyddd_to_date,
)

FIX = Path(__file__).parent / "fixtures"


# --------------------------------------------------------------------------- #
#  Date helper                                                                #
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("code,expected", [
    (2024264, "2024-09-20"),   # YYYYDDD
    (24264, "2024-09-20"),     # YYDDD, <80 -> 20xx
    (98001, "1998-01-01"),     # YYDDD, >=80 -> 19xx
])
def test_yyddd_to_date(code, expected):
    assert yyddd_to_date(code) == pd.Timestamp(expected)


@pytest.mark.parametrize("bad", [-99, 0, "", "abc", None, 2024400])
def test_yyddd_to_date_missing(bad):
    assert pd.isna(yyddd_to_date(bad))


# --------------------------------------------------------------------------- #
#  Time-series: PlantGro.OUT                                                   #
# --------------------------------------------------------------------------- #
def test_plantgro_basic():
    df = parse_plantgro(FIX / "PlantGro.OUT")
    assert not df.empty
    # known columns from the wheat CERES growth file
    for col in ("YEAR", "DOY", "DAP", "GSTD", "LAID", "CWAD", "run", "treatment",
                "rotation", "date", "crop_model"):
        assert col in df.columns, col
    # first row: 2024 DOY 264 -> 2024-09-20, DAP 0
    first = df.iloc[0]
    assert first["YEAR"] == 2024 and first["DOY"] == 264
    assert first["date"] == pd.Timestamp("2024-09-20")
    assert df["run"].iloc[0] == 1
    assert df["crop_model"].iloc[0] == "CSCER048"
    # values are numeric and the -99 sentinel became NaN (TKILL stays -6, SWXD 99.9)
    assert pd.api.types.is_numeric_dtype(df["LAID"])
    # SLAD column is all -99 in early rows -> should be NaN there
    assert df["SLAD"].isna().any()


def test_plantgro_monotonic_dap():
    df = parse_plantgro(FIX / "PlantGro.OUT")
    dap = df["DAP"].dropna().to_numpy()
    assert (np.diff(dap) >= 0).all()   # days after planting only increases


def test_timeseries_matches_csv_twin():
    """PlantGro.OUT and its plantgro.csv twin should agree on shared columns."""
    out = parse_plantgro(FIX / "PlantGro.OUT").reset_index(drop=True)
    csv = parse_csv(FIX / "plantgro.csv").reset_index(drop=True)
    assert len(out) == len(csv)
    # integer-valued growth column matches exactly
    a = out["CWAD"].to_numpy(dtype=float)
    b = csv["CWAD"].to_numpy(dtype=float)
    assert np.allclose(a, b, equal_nan=True)
    # the .OUT writes LAID rounded to 2 decimals for display while the CSV keeps
    # full precision, so they agree only to that display tolerance (~0.02).
    assert np.allclose(out["LAID"].to_numpy(float),
                       csv["LAID"].to_numpy(float), equal_nan=True, atol=0.02)


def test_other_timeseries_files_parse():
    for fname, col in [("PlantN.OUT", "NUAC"),
                       ("MgmtOps.OUT", "IRRC"),
                       ("GHG.OUT", "CO2EC")]:
        df = parse_timeseries(FIX / fname)
        assert not df.empty, fname
        assert col in df.columns, f"{col} missing in {fname}"
        assert "run" in df.columns


# --------------------------------------------------------------------------- #
#  Sequence (.SQX) format: multi-RUN, per-block headers, differing columns     #
# --------------------------------------------------------------------------- #
def test_real_sequence_multiseason_blocks():
    """Real mode-Q rotation output: 3 consecutive season blocks from a 40-year
    Hemp/Fallow sequence run (DSSAT dscsm048 Q)."""
    df = parse_timeseries(FIX / "SeqRealPlantGro.OUT")
    assert not df.empty
    assert sorted(df["run"].dropna().unique()) == [1, 2, 3]
    # each block is a distinct season/year, carried by the rotation
    assert df.groupby("run")["YEAR"].first().nunique() == 3
    assert df["crop_model"].iloc[0] == "CRGRO048"


def test_sequence_rotation_blocks():
    df = parse_timeseries(FIX / "SeqPlantGro.OUT")
    assert not df.empty
    # two rotation phases, distinct run numbers and crop models
    assert set(df["rotation"].dropna().unique()) == {1, 2}
    assert set(df["run"].dropna().unique()) == {1, 2}
    assert set(df["crop_model"].dropna().unique()) == {"MZCER048", "CRGRO048"}
    # phase-1 (maize) has no PODWT column -> NaN there; phase-2 (soy) has values
    maize = df[df["rotation"] == 1]
    soy = df[df["rotation"] == 2]
    assert maize["PODWT"].isna().all()        # column only exists for soy block
    assert soy["PODWT"].notna().any()
    # shared columns line up
    assert maize["CWAD"].notna().any() and soy["CWAD"].notna().any()


# --------------------------------------------------------------------------- #
#  Summary.OUT  (fixed-width, spacey TNAM)                                     #
# --------------------------------------------------------------------------- #
def test_summary_fixed_width():
    df = parse_summary(FIX / "Summary.OUT")
    assert not df.empty
    assert len(df) == 2   # the maize Summary fixture has 2 runs
    # spacey text column recovered intact
    assert df["TNAM"].iloc[0] == "AG9010 - Rainfed"
    assert df["CR"].iloc[0] == "MZ"
    assert df["MODEL"].iloc[0] == "MZCER048"
    # numeric columns coerced
    assert df["HWAM"].iloc[0] == 4329
    assert df["CWAM"].iloc[0] == 10788
    # date twins derived from *DAT codes
    assert "PDAT_date" in df.columns and "MDAT_date" in df.columns
    assert df["PDAT_date"].iloc[0] == pd.Timestamp("2002-03-13")  # 2002072


def test_summary_runno_sequential():
    df = parse_summary(FIX / "Summary.OUT")
    assert list(df["RUNNO"]) == [1, 2]


# --------------------------------------------------------------------------- #
#  Evaluate.OUT                                                                #
# --------------------------------------------------------------------------- #
def test_evaluate_pairs():
    df = parse_evaluate(FIX / "Evaluate.OUT")
    # may be small but must have the long schema
    assert list(df.columns) == ["treatment", "run", "variable", "sim", "meas"]
    if not df.empty:
        assert df["variable"].notna().all()


# --------------------------------------------------------------------------- #
#  CSV twin: summary.csv                                                       #
# --------------------------------------------------------------------------- #
def test_summary_csv():
    df = parse_csv(FIX / "summary.csv")
    assert not df.empty
    assert "HWAM" in df.columns
    assert "PDAT_date" in df.columns
    # -99 sentinel mapped to NaN (EYLDH is -99 in this wheat run)
    assert df["EYLDH"].isna().all()


# --------------------------------------------------------------------------- #
#  Dispatcher + directory reader                                              #
# --------------------------------------------------------------------------- #
def test_dispatch_by_name():
    assert not parse_dssat_output(FIX / "Summary.OUT").empty
    assert not parse_dssat_output(FIX / "PlantGro.OUT").empty
    assert not parse_dssat_output(FIX / "summary.csv").empty


def test_read_run_directory_explicit():
    res = read_run_directory(FIX, files=["Summary.OUT", "PlantGro.OUT"])
    assert set(res.keys()) == {"summary", "plantgro"}
    assert not res["summary"].empty and not res["plantgro"].empty


def test_read_run_directory_auto_skips_non_tabular():
    res = read_run_directory(FIX)
    # tabular time-series + summary present
    assert "plantgro" in res and "plantn" in res
    # non-tabular balance file skipped
    assert "soilnibal" not in res


def test_read_run_directory_includes_csv_twins():
    """A CSV-mode run keeps daily data in .csv, not .OUT — include_csv (default)
    must pick those up; the fixtures dir has plantgro.csv + summary.csv etc."""
    res = read_run_directory(FIX)
    # somlitc_trailcomma.csv has no .OUT counterpart -> only seen with include_csv
    assert "somlitc_trailcomma" in res
    # a stem present as both .OUT and .csv (plantgro) resolves to the .OUT
    assert "plantgro" in res
    # disabling include_csv drops csv-only stems
    res_no = read_run_directory(FIX, include_csv=False)
    assert "somlitc_trailcomma" not in res_no
    assert "plantgro" in res_no


def test_csv_trailing_comma_robustness():
    """DSSAT writes a trailing comma on some CSVs (data rows carry one extra empty
    field vs the header) — must parse without column misalignment."""
    df = parse_csv(FIX / "somlitc_trailcomma.csv")
    assert not df.empty
    assert "RUN" in df.columns and "CO2SC" in df.columns   # first & last real cols
    assert df["YEAR"].iloc[0] == 1984


# --------------------------------------------------------------------------- #
#  Non-daily tables: Leaves.OUT (keyed by leaf #) and balance summaries        #
#  (real DSSAT output from a 6-treatment wheat experiment)                     #
# --------------------------------------------------------------------------- #
def test_leaves_non_daily_header():
    """Leaves.OUT keys on @ LNUM (leaf number), not YEAR/DOY — must still parse."""
    df = parse_timeseries(FIX / "Leaves.OUT")
    assert not df.empty
    assert "LNUM" in df.columns
    # 6 treatments x 9 leaves
    assert sorted(df["run"].dropna().unique()) == [1, 2, 3, 4, 5, 6]
    assert df["LNUM"].min() == 1
    assert "date" not in df.columns or df["date"].isna().all()   # no YEAR/DOY here


def test_balance_summary_one_row_per_run():
    """SoilNBalSum.OUT is a per-run balance summary (@Run FILEX TN CR …)."""
    df = parse_dssat_output(FIX / "SoilNBalSum.OUT")
    assert not df.empty
    assert len(df) == 6                       # one row per treatment
    assert "Run" in df.columns and "SNBAL" in df.columns
    assert list(df["Run"]) == [1, 2, 3, 4, 5, 6]


def test_summary_six_runs():
    df = parse_summary(FIX / "Summary6.OUT")
    assert len(df) == 6
    assert list(df["RUNNO"]) == [1, 2, 3, 4, 5, 6]
    # the 6 N-rate/irrigation treatments give distinct grain yields
    assert df["HWAM"].nunique() > 1


def test_multitreatment_blocks_are_split():
    """A real 6-treatment experiment yields 6 *RUN blocks in each daily file."""
    df = parse_plantgro(FIX / "PlantGro.OUT")  # single-run wheat fixture -> 1 block
    assert df["run"].nunique() == 1
    # but Plantsum.OUT from the 6-treatment run carries all six
    ps = parse_timeseries(FIX / "Plantsum.OUT")
    assert not ps.empty and len(ps) == 6


def test_overview_is_skipped_as_report():
    # OVERVIEW embeds '@' tables but is a free-text report -> dispatcher returns empty
    assert parse_dssat_output(FIX / "OVERVIEW.OUT" if (FIX / "OVERVIEW.OUT").exists()
                              else FIX / "SoilNiBal.OUT").empty


# --------------------------------------------------------------------------- #
#  Robustness                                                                 #
# --------------------------------------------------------------------------- #
def test_missing_file_returns_empty():
    assert parse_timeseries(FIX / "DOES_NOT_EXIST.OUT").empty
    assert parse_summary(FIX / "nope.OUT").empty
    assert parse_csv(FIX / "nope.csv").empty


def test_non_tabular_file_returns_empty():
    # SoilNiBal.OUT has *RUN but no @YEAR table -> no data block
    assert parse_timeseries(FIX / "SoilNiBal.OUT").empty
