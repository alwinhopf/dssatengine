# Changelog & Versioning Conventions

## [0.4.1] - 2026-08-27

### Fixed
- **Point-specific FileX selection for batch and sequence runs.** Both R and
  Python now canonicalize the prepared experiment/sequence file to
  `<point ID>.<ext>` and write that name to `DSSBatch.V48`. R previously wrote
  a patched `<ID>.SQX` but ran a newly copied, untouched template file, leaving
  `WID00000`/`SID00000` placeholders active and causing every sequence run to
  fail with `Weather file not found: WID00000.WTH`. Regression tests cover both
  supported folder-builder conventions.

## Versioning Conventions

`dssatengine` adheres to Semantic Versioning (SemVer) with the following specific rules:

- **Patch releases (v0.x.Y)**: Bug fixes, performance improvements, and documentation updates. No changes to public API signatures or behaviors.
- **Minor releases (v0.X.0)**: New features, new exported functions, or backward-compatible modifications to existing capabilities.
- **Major releases (v1.0.0+)**: Breaking changes to the public API, removal of deprecated components, or significant design overhauls.

---

## [0.4.0] - 2026-06-23

### Fixed
- **`write_dssbatch_sequence` column alignment (sequence/mode-Q runs).** The SQ
  (rotation) field was written at columns 103-108, but CSM.for reads the batch
  treatment fields from `CHARTEST(93:113)` with `FORMAT(3(1X,I6))` — TRTNO at
  94-99, RP at 101-106, **ROTNO/SQ at 108-113**. The misplaced field made DSSAT
  mis-read the rotation number and abort every sequence run with libgfortran
  IOSTAT 5010 (read overflow) while parsing the FileX. Both R and Python now emit
  `<92-wide FileX> SP TRTNO SP RP SP SQ SP OP SP CO`, verified by a real 40-year
  Hemp/Fallow `.SQX` rotation that now completes (41 season blocks). Experiment
  (mode-A) batches were unaffected (mode A ignores RP/SQ). A column-position
  regression test guards this in both languages.

### Added
- **Output parsers** (R + Python parity, `output_parser.py` / `parser.R`) — the
  `run → parse` half of the engine, so consumers no longer hand-roll DSSAT
  output reading:
  - `parse_timeseries` — any `.OUT` block table with an `@` column header. Covers
    every daily series (`PlantGro`, `PlantN`, `PlantGr2`, `PlantGrf`, `MgmtOps`,
    `MgmtEvent`, `GHG`, `N2O`, `Mulch`, `ET`, `SoilWat`, `SoilWater`, `SoilNi`,
    `SoilOrg`, `SoilTemp`, `Weather`, …) plus non-daily tables keyed differently —
    `Leaves.OUT` (by leaf number) and the per-season balance summaries
    (`SWBalSum`, `SoilCBalSum`, `SoilNBalSum`, one row per run). One row per
    (run, row) with `run`/`treatment`/`crop_model`/`rotation` ids and a derived
    `date` when YEAR+DOY are present. Aliases `parse_plantgro`, `parse_plantn`.
  - `parse_summary` — robust fixed-width `Summary.OUT` reader that recovers
    spacey text columns (`TNAM`, `FNAM`, `MODEL`) by header column positions and
    adds `*_date` twins for `*DAT` codes.
  - `parse_evaluate` — long simulated-vs-measured table from `Evaluate.OUT`
    (treatment read from `TRNO`, falling back to `TN`).
  - `parse_csv` — `FMOPT='C'` CSV twins (`summary.csv`, `plantgro.csv`) with the
    same `-99 → NA` and date conventions, so CSV and text runs are interchangeable.
  - `parse_dssat_output` (dispatcher) and `read_run_directory` (whole-folder
    reader; auto-skips non-tabular balances/reports, or pass an explicit file
    list — the common `["Summary.OUT", "PlantGro.OUT"]` case). `read_run_directory`
    also reads the `FMOPT='C'` `.csv` twins by default (`include_csv=True`) so a
    CSV-mode run — whose daily data lands in `plantgro.csv` etc., not `.OUT` — is
    read as fully as a text run; when both forms of a file exist the `.OUT` wins.
  - `parse_csv` tolerates DSSAT's trailing-comma rows (some CSVs write one extra
    empty field per data row) without column misalignment.
  - `yyddd_to_date` helper for DSSAT `YYDDD`/`YYYYDDD` date codes.
- **Sequence (.SQX) support**: multi-`*RUN` files whose rotation phases carry
  different crop headers are concatenated by column name (missing columns → NA),
  with `rotation`/`crop_model` distinguishing phases.
- Tests: `tests/test_output_parser.py` and `tests/testthat/test_output_parser.R`
  (R/Python parity), run against real DSSAT 4.8 fixtures in `tests/fixtures/`.
  Verified end-to-end by re-running a wheat experiment with **all** output
  switches on (`GROUT/CAOUT/WAOUT/NIOUT/MIOUT/CHOUT/OPOUT/VBOSE`) in both text
  (`FMOPT=A`, 32 `.OUT` types) and CSV (`FMOPT=C`, 14 `.csv` + 23 `.OUT`) modes,
  with 6 treatments → 6 `*RUN` blocks per file: every data table parsed, only the
  free-text reports/narrative balances (`OVERVIEW`, `INFO`, `*Bal`, run lists) are
  skipped by design. Sequence mode covered too: a real mode-Q 40-year Hemp/Fallow
  rotation (`.SQX`) parsed in both formats — 41 season blocks split correctly,
  continuous whole-run files (ET/GHG/SoilWat) and per-season-block files
  (PlantGro/MgmtOps/Evaluate) both handled.

## [0.3.0] - 2026-06-18

### Added
- Public R/Python execution helpers: `run_dssat`, `write_dssbatch`,
  `write_dssbatch_sequence`, and Python `normalize_treatment_list`.
- Python `run_dssat(..., model=..., timeout=...)` supports DSSAT builds that
  expect a crop-model argument before the run mode (for example
  `CRGRO048 B DSSBatch.V48`), while preserving the original engine call shape.

### Changed
- `run_simulation` now calls the public batch/execution helpers internally.
- Private Python helper names remain as backward-compatible aliases for existing
  consumers.

## [0.2.0] - 2026-06-17

### Added
- R and Python `run_simulation` support for explicit non-contiguous treatment IDs
  through `treatment_list`, while preserving the contiguous `treatment_start` /
  `treatment_end` range.
- Fast Python tests for treatment-list normalization and DSSAT batch-file writing,
  plus a mirrored R `testthat` parity test (`tests/testthat/`).
- `normalize_treatment_list` is now an exported top-level R function (previously nested
  inside `run_simulation`), mirroring Python's `_normalize_treatment_list` so both sides
  are unit-testable.

### Fixed
- Python DSSAT execution now captures stdout/stderr, writes a per-run log, and raises
  on non-zero DSSAT exit codes instead of silently discarding failures.
- Engine-owned text I/O now uses explicit UTF-8 encoding in both R and Python.

## [0.1.0] - 2026-06-09

### Added
- Initial extraction of the gridded engine from `DSSAT_Gridded_Run_Tutorial` into a shared `dssatengine` library.
- Parallelized R and Python interfaces supporting spatial gridded runs.
- Config-driven execution options, weather/soil switches, and multi-core resource settings.
- Vectorized aggregation of results.

### Fixed
- `_write_dssbatch` / `_write_dssbatch_sequence` (Python): the FileX field no longer
  carries a leading space, so the entry starts at column 1. A leading space made
  CSM.for compute a negative substring index (`Substring out of bounds`) and crash on
  sequence/batch runs.
