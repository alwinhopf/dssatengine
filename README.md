# dssatengine

> **AI agents & maintainers:** read [`../AGENTS.md`](../AGENTS.md) before editing this repo.

The **canonical gridded DSSAT-CSM execution engine**, shipped as a dual-language package
(R + Python) with matching function names. It is the extracted, version-pinned home for the
points → weather + soil → FileX → run → parse workflow that consumer repos used to hand-copy.

Consumers use this package through their selected gridded-engine environment:
`DSSAT_Gridded_Run_Tutorial` imports it inside `dssat_main_pipeline.{py,R}`;
`DSSAT_SubField_MILP_Analysis` shells out to that sibling gridded engine via
`DSSAT_ENGINE_DIR`; and `Bioenergy_Model_Input_Comparison` points at the engine via
`ENGINE_DIR`. Application repos should carry **zero local engine definitions**, so a
fix lands once and reaches consumers when their pinned/shared engine environment is
bumped.

> For how this package fits the wider workspace, see the canonical
> [`ARCHITECTURE.md`](../DSSAT_Gridded_Run_Tutorial/ARCHITECTURE.md), the pins in
> [`DEPENDENCIES.md`](DEPENDENCIES.md), and the shared rules in [`CONVENTIONS.md`](CONVENTIONS.md).

## What's inside

Both languages expose the same public surface (`R/engine.R`, `python/dssatengine/engine.py`):
the root packages also export the shared `LAT_COLUMN`, `LONG_COLUMN`, and
`POINT_ID_COLUMN` schema constants.

| Function (same name in R and Python) | Role |
|---|---|
| `create_grid_points` | Build a regular grid of points inside a boundary polygon (Albers EPSG:5070), write a point shapefile with `LAT`/`LONG`/`ID`. |
| `load_existing_points` | Load a user point/polygon shapefile, reproject to EPSG:4326, normalize/regenerate the `ID` column. |
| `extend_weather_repeat_single_ignore_partial` | Extend a `.WTH` file to a target end year by repeating a complete reference year (month-day matched, leap-aware), preserving `YYDDD`/`YYYYDDD` format. |
| `normalize_treatment_list` | Normalize contiguous or explicit treatment selections into ordered, deduplicated positive integers. |
| `write_dssbatch` / `write_dssbatch_sequence` | Write DSSAT `DSSBatch.V48` files with the FileX field starting in column 1. |
| `run_dssat` | Spawn DSSAT with stdout/stderr logging and non-zero exit handling; supports optional crop-model argument for custom builds. |
| `run_simulation` | Build a per-point DSSAT run folder, write `DSSBatch.V48`, spawn `dscsm048`, parse `summary.csv` (+ `soilorg`/`soilni`/`soilwat` supplements) into a tidy results frame. |

### Output parsers (`output_parser.py` / `parser.R`)

The `run → parse` half of the engine. Same function names in both languages;
`-99` maps to NaN/NA and dates are derived from `YEAR`+`DOY` / `*DAT` codes.

| Function | Role |
|---|---|
| `parse_timeseries` | Any `.OUT` block table with an `@` header — daily series (`PlantGro`, `PlantN`, `PlantGr2`, `MgmtOps`, `GHG`, `N2O`, `Mulch`, `ET`, `SoilWat`, `SoilNi`, `SoilOrg`, `SoilTemp`, `Weather`, …) **and** non-daily tables (`Leaves` by leaf #, the `*BalSum` per-run balance summaries) → one row per (run, row) with `run`/`treatment`/`crop_model`/`rotation` and a `date` when YEAR+DOY exist. Aliases: `parse_plantgro`, `parse_plantn`. |
| `parse_summary` | Fixed-width `Summary.OUT` → one row per run; recovers spacey `TNAM`/`FNAM`/`MODEL` by header column positions; adds `*_date` twins. |
| `parse_evaluate` | `Evaluate.OUT` → long `(treatment, run, variable, sim, meas)` table. |
| `parse_csv` | `FMOPT='C'` CSV twins (`summary.csv`, `plantgro.csv`) with identical conventions. |
| `parse_dssat_output` / `read_run_directory` | Dispatch one file by name/structure; read a whole run folder. `read_run_directory` auto-skips non-tabular balances/reports and (by default, `include_csv`) also reads the `FMOPT='C'` `.csv` twins. A CSV twin is preferred when both exist because it is structurally safer and may be newer; or pass an explicit file list — typically `["Summary.OUT", "PlantGro.OUT"]`. |

**Sequence (.SQX) note.** Sequence simulations write multi-`*RUN` files whose
rotation phases may be *different crops with different headers*; the parsers keep
each block's own header, concatenate by column name (missing columns → NA), and
tag every row with `rotation`/`crop_model` so phases stay separable. Experiment
(`.??X`) runs have one block per treatment with a shared header.

```python
from dssatengine import read_run_directory, parse_summary, parse_plantgro
run = read_run_directory("dssat_runs/0001", files=["Summary.OUT", "PlantGro.OUT"])
yields, daily = run["summary"], run["plantgro"]
```

`run_simulation` supports two run modes — `experiment` (mode `B`, using
`DSSBatch.V48`) and `sequence` (mode `Q`) —
and selects treatments either as a contiguous `treatment_start … treatment_end` range or as an
explicit, possibly non-contiguous `treatment_list` (e.g. `[5, 1, 10]`, order-preserving and
deduplicated). The legacy `treatments` argument is deprecated and may not be combined with
`treatment_list`. The Python package additionally exposes the private `_run_one_point` /
`_run_simulation` helpers used by the parallel drivers.

## Behavior guarantees (cross-platform & failsafe)

Per [`CONVENTIONS.md`](CONVENTIONS.md) §6, the engine:

- **Captures and validates DSSAT exit codes.** A non-zero `dscsm048` exit raises with a log
  path and a tail of stdout/stderr (R and Python); failures are never discarded silently.
- **Writes the FileX field starting at column 1** in `DSSBatch.V48` — a leading space makes
  `CSM.for` compute a negative substring index and crash (`Substring out of bounds`).
- **Uses explicit UTF-8** for engine-owned text I/O and emits LF line endings.
- **Resolves the executable dynamically** (`dscsm048` / `dscsm048.exe`) and never invokes a shell.

## Install

### Python
```bash
pip install "git+https://github.com/alwinhopf/dssatengine.git@2280b11977ad373b9ae19d2d4497e8f276f7b133"
```
or pin in `requirements.txt`:
```
dssatengine @ git+https://github.com/alwinhopf/dssatengine.git@2280b11977ad373b9ae19d2d4497e8f276f7b133
```
```python
from dssatengine import create_grid_points, load_existing_points, run_dssat
from dssatengine.engine import _run_one_point   # parallel-driver entry point
```

### R
```r
# install.packages("remotes")
remotes::install_github("alwinhopf/dssatengine@2280b11977ad373b9ae19d2d4497e8f276f7b133")
library(dssatengine)
```

## Versioning & pinning

Semantic versioning with git tags. Consumers pin to an immutable release tag or full
commit SHA, never `main`, so upstream changes cannot alter an environment silently.
The verified workspace baseline is commit `2280b11977ad373b9ae19d2d4497e8f276f7b133`;
per-consumer pins are tracked in
[`DEPENDENCIES.md`](DEPENDENCIES.md), and the change history is in [`NEWS.md`](NEWS.md).

## Testing

```bash
# Python (fast, offline — no DSSAT binary needed)
python -m pytest -q
```
```r
# R
testthat::test_dir("tests/testthat")
```

The fast tests cover treatment-list normalization, `DSSBatch.V48` writing, and the
output parsers — the latter against real DSSAT 4.8 fixtures in `tests/fixtures/` — in
both languages (R/Python parity per [`CONVENTIONS.md`](CONVENTIONS.md) §3). End-to-end
runs that spawn `dscsm048` require a DSSAT48 install and live in the consumer pipelines.
