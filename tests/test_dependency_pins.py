import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UTILS_REF = "e9c859fa1d915623df23e2eb13084cb085dbfe3e"


def test_r_dependency_and_ci_use_same_dssatutils_revision():
    description = (ROOT / "DESCRIPTION").read_text(encoding="utf-8")
    workflow = (ROOT / ".github" / "workflows" / "tests.yml").read_text(
        encoding="utf-8"
    )
    match = re.search(r"alwinhopf/dssatutils@([0-9a-f]{40})", description)
    assert match, "DESCRIPTION must pin dssatutils to an immutable commit"
    assert match.group(1) == UTILS_REF
    assert f"github::alwinhopf/dssatutils@{UTILS_REF}" in workflow
    assert "GITHUB_PAT: ${{ github.token }}" in workflow
