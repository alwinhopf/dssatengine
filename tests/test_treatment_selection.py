import os
import stat
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

import pytest
import pandas as pd

from dssatengine import (
    LAT_COLUMN, LONG_COLUMN, POINT_ID_COLUMN, append_utf8,
    normalize_treatment_list, run_dssat, safe_write_lines, write_dssbatch,
    write_sequence_phase_file,
)
from dssatengine import engine as engine_module


def test_contiguous_treatment_range():
    assert normalize_treatment_list(2, 4) == [2, 3, 4]


def test_root_column_constants_match_r_public_surface():
    assert (LAT_COLUMN, LONG_COLUMN, POINT_ID_COLUMN) == ("LAT", "LONG", "ID")


def test_explicit_noncontiguous_treatment_list_preserves_order():
    assert normalize_treatment_list(1, 99, treatment_list=[5, 1, 5, "10"]) == [5, 1, 10]


def test_empty_treatment_selection_fails_clearly():
    try:
        normalize_treatment_list(4, 1)
    except ValueError as exc:
        assert "treatment_end" in str(exc)
    else:
        raise AssertionError("Expected invalid treatment range to fail")


@pytest.mark.parametrize("value", [1.9, "abc", float("nan")])
def test_invalid_explicit_treatment_is_not_silently_coerced(value):
    with pytest.raises(ValueError, match="integer"):
        normalize_treatment_list(1, 1, treatment_list=[value])


def test_write_dssbatch_uses_explicit_treatments(tmp_path):
    batch = tmp_path / "DSSBatch.V48"
    write_dssbatch("CARINATA1984.SQX", [1, 5, 10], str(batch), run_mode="experiment")
    text = batch.read_text(encoding="utf-8")
    assert "CARINATA1984.SQX" in text
    assert "     1" in text
    assert "     5" in text
    assert "    10" in text


def test_write_dssbatch_sequence_column_layout(tmp_path):
    """SEQUENCE mode is column-sensitive: CSM.for reads CHARTEST(93:113) with
    FORMAT(3(1X,I6)) -> TRTNO@94-99, RP@101-106, ROTNO/SQ@108-113. If SQ lands
    anywhere else, DSSAT aborts with IOSTAT 5010. Guard the exact positions."""
    from dssatengine import write_dssbatch_sequence
    batch = tmp_path / "DSSBatch.V48"
    write_dssbatch_sequence("00000003.SQX", trt=2, seq_start=1, seq_end=3, batch_path=str(batch))
    data = [ln for ln in batch.read_text(encoding="utf-8").splitlines()
            if ln.startswith("00000003.SQX")]
    assert len(data) == 3
    for i, ln in enumerate(data, start=1):
        assert ln.startswith("00000003.SQX")        # FileX in column 1
        assert ln[93:99] == "     2"                 # TRTNO cols 94-99
        assert ln[100:106] == "     1"               # RP cols 101-106
        assert ln[107:113] == f"{i:6d}"              # SQ/ROTNO cols 108-113


def test_point_filex_resolution_prefers_patched_id_file(tmp_path):
    point_id = "00000001"
    raw_template = tmp_path / "source" / "CARINATA1984.SQX"
    raw_template.parent.mkdir()
    raw_template.write_text("WID00000\n", encoding="utf-8")

    point_dir = tmp_path / point_id
    point_dir.mkdir()
    (point_dir / raw_template.name).write_text("WID00000\n", encoding="utf-8")
    patched = point_dir / f"{point_id}.SQX"
    patched.write_text(f"{point_id}\n", encoding="utf-8")

    resolved = engine_module._resolve_point_filex(
        point_id, raw_template.name, str(raw_template), point_dir
    )
    assert Path(resolved) == patched
    assert patched.read_text(encoding="utf-8") == f"{point_id}\n"

    batch = point_dir / "DSSBatch.V48"
    engine_module.write_dssbatch_sequence(resolved, 4, 1, 1, str(batch))
    assert any(line.startswith(f"{point_id}.SQX")
               for line in batch.read_text(encoding="utf-8").splitlines())


def test_point_filex_resolution_canonicalizes_prepared_template(tmp_path):
    point_id = "00000002"
    raw_template = tmp_path / "source" / "CARINATA1984.SQX"
    raw_template.parent.mkdir()
    raw_template.write_text("WID00000\n", encoding="utf-8")

    point_dir = tmp_path / point_id
    point_dir.mkdir()
    prepared = point_dir / raw_template.name
    prepared.write_text(f"{point_id}\n", encoding="utf-8")

    resolved = Path(engine_module._resolve_point_filex(
        point_id, raw_template.name, str(raw_template), point_dir
    ))
    assert resolved.name == f"{point_id}.SQX"
    assert resolved.read_text(encoding="utf-8") == f"{point_id}\n"


def _fake_dssat_exe(tmp_path: Path, exit_code: int = 0) -> Path:
    if os.name == "nt":
        exe = tmp_path / "fake_dssat.bat"
        exe.write_text(
            "@echo off\n"
            "echo %* > args.txt\n"
            "echo fake dssat stdout\n"
            f"exit /B {exit_code}\n",
            encoding="utf-8",
        )
    else:
        exe = tmp_path / "fake_dssat"
        exe.write_text(
            "#!/bin/sh\n"
            "echo \"$@\" > args.txt\n"
            "echo fake dssat stdout\n"
            f"exit {exit_code}\n",
            encoding="utf-8",
        )
        exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
    return exe


def test_run_dssat_captures_logs_and_model_argument(tmp_path):
    exe = _fake_dssat_exe(tmp_path)
    run_dssat(str(tmp_path), str(exe), "B", model="CRGRO048")

    assert (tmp_path / "args.txt").read_text(encoding="utf-8").strip() == "CRGRO048 B DSSBatch.V48"
    assert "fake dssat stdout" in (tmp_path / "dssat_B_stdout_stderr.log").read_text(encoding="utf-8")


def test_run_dssat_raises_on_nonzero_exit(tmp_path):
    exe = _fake_dssat_exe(tmp_path, exit_code=7)

    with pytest.raises(RuntimeError, match="status 7"):
        run_dssat(str(tmp_path), str(exe), "B")

    assert "fake dssat stdout" in (tmp_path / "dssat_B_stdout_stderr.log").read_text(encoding="utf-8")


def test_experiment_run_uses_batch_mode_to_honour_treatment_selection(tmp_path, monkeypatch):
    """Mode A ignores DSSBatch.V48 and runs every FileX treatment. Experiment
    selection must therefore invoke mode B, as the R engine does."""
    point_id = "00000001"
    point_dir = tmp_path / point_id
    point_dir.mkdir()
    template = point_dir / "TEST0001.MZX"
    template.write_text("*EXP.DETAILS\n", encoding="utf-8")

    invocations = []

    def fake_run_dssat(run_dir, exe, mode, **kwargs):
        invocations.append((run_dir, exe, mode, kwargs))

    summary = pd.DataFrame({
        "RUNNO": [1], "TRNO": [3], "CR": ["MZ"], "LAT": [1.0],
        "LONG": [2.0], "WSTA": [point_id], "SOIL_ID": [point_id],
        "EXNAME": ["TEST0001"], "TNAM": ["selected"], "PDAT": [1984120],
        "EDAT": [1984125], "HDAT": [1984250], "HYEAR": [1984],
        "CWAM": [1000.0], "HWAM": [500.0], "BWAH": [0.0],
        "CO2EM": [0.0], "N2OEM": [0.0],
    })

    monkeypatch.setattr(engine_module, "run_dssat", fake_run_dssat)
    monkeypatch.setattr(engine_module, "_read_csv_safe", lambda path: summary.copy())
    monkeypatch.setattr(engine_module, "_merge_supplemental", lambda path, runs: runs)

    result = engine_module._run_simulation(
        point_id, pd.Series({"LAT": 1.0, "LONG": 2.0}),
        str(tmp_path), "MZ", template.name, str(template), "experiment",
        3, 3, 1, 1, 1984, 1984, "/fake/dssat",
    )

    assert result is not None and result["treatment"].tolist() == [3]
    assert len(invocations) == 1
    assert invocations[0][2] == "B"
    assert invocations[0][3] == {}


def test_r_parity_file_helpers(tmp_path):
    text = tmp_path / "text.txt"
    safe_write_lines(["one", "two"], text, delay_sec=0)
    append_utf8(text, "three")
    assert text.read_text(encoding="utf-8") == "one\ntwo\nthree\n"

    source = tmp_path / "source.SQX"
    target = tmp_path / "target.SQX"
    source.write_text(
        "*TREATMENTS\n"
        "@N R O C TNAME....................\n"
        " 1 1 1 0 first\n"
        " 2 1 1 0 second\n"
        "*CULTIVARS\n",
        encoding="utf-8",
    )
    write_sequence_phase_file(source, target, treatment=2, phase=1)
    rendered = target.read_text(encoding="utf-8")
    assert "second" in rendered and "first" not in rendered
    with pytest.raises(ValueError, match="No sequence treatment row"):
        write_sequence_phase_file(source, target, treatment=9, phase=1)
