import os
import stat
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

import pytest

from dssatengine import normalize_treatment_list, run_dssat, write_dssbatch


def test_contiguous_treatment_range():
    assert normalize_treatment_list(2, 4) == [2, 3, 4]


def test_explicit_noncontiguous_treatment_list_preserves_order():
    assert normalize_treatment_list(1, 99, treatment_list=[5, 1, 5, "10"]) == [5, 1, 10]


def test_empty_treatment_selection_fails_clearly():
    try:
        normalize_treatment_list(4, 1)
    except ValueError as exc:
        assert "treatment_end" in str(exc)
    else:
        raise AssertionError("Expected invalid treatment range to fail")


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
