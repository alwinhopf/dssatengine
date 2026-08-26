from pathlib import Path
import sys

import geopandas as gpd
import pytest
from shapely.geometry import box

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from dssatengine import (  # noqa: E402
    create_grid_points,
    create_master_grid_points,
    derive_nested_grid_points,
)


def _boundary():
    return gpd.GeoDataFrame({"name": ["test"]}, geometry=[box(0, 0, 4000, 4000)], crs="EPSG:5070")


def test_master_grid_subsets_are_exact_and_stable(tmp_path):
    master = create_master_grid_points(
        _boundary(), 1000, tmp_path / "master.gpkg",
        grid_crs="EPSG:5070", origin_x=0, origin_y=0,
    )
    grid_2k = derive_nested_grid_points(master, 2000, tmp_path / "grid_2k.gpkg")
    grid_4k = derive_nested_grid_points(master, 4000, tmp_path / "grid_4k.gpkg")

    assert len(master) == 25
    assert len(grid_2k) == 9
    assert len(grid_4k) == 4
    assert set(grid_4k["ID"]) < set(grid_2k["ID"]) < set(master["ID"])
    assert set(grid_2k["MROW"] % 2) == {0}
    assert set(grid_2k["MCOL"] % 2) == {0}
    assert grid_2k["MSPACE_M"].eq(1000).all()
    assert grid_2k["SAMP_M"].eq(2000).all()
    assert grid_2k["NEST_F"].eq(2).all()


def test_master_grid_requires_integer_spacing_multiple(tmp_path):
    master = create_master_grid_points(
        _boundary(), 1000, tmp_path / "master.gpkg", grid_crs="EPSG:5070"
    )
    with pytest.raises(ValueError, match="integer multiple"):
        derive_nested_grid_points(master, 1500, tmp_path / "bad.gpkg")


def test_legacy_independent_grid_remains_available(tmp_path):
    legacy = create_grid_points(_boundary(), 2000, tmp_path / "legacy.gpkg")
    assert len(legacy) > 0
    assert "MROW" not in legacy.columns

