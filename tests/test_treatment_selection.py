from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from dssatengine.engine import _normalize_treatment_list, _write_dssbatch


def test_contiguous_treatment_range():
    assert _normalize_treatment_list(2, 4) == [2, 3, 4]


def test_explicit_noncontiguous_treatment_list_preserves_order():
    assert _normalize_treatment_list(1, 99, treatment_list=[5, 1, 5, "10"]) == [5, 1, 10]


def test_empty_treatment_selection_fails_clearly():
    try:
        _normalize_treatment_list(4, 1)
    except ValueError as exc:
        assert "treatment_end" in str(exc)
    else:
        raise AssertionError("Expected invalid treatment range to fail")


def test_write_dssbatch_uses_explicit_treatments(tmp_path):
    batch = tmp_path / "DSSBatch.V48"
    _write_dssbatch("CARINATA1984.SQX", [1, 5, 10], str(batch), run_mode="experiment")
    text = batch.read_text(encoding="utf-8")
    assert "CARINATA1984.SQX" in text
    assert "     1" in text
    assert "     5" in text
    assert "    10" in text
