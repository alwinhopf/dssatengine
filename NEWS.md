# Changelog & Versioning Conventions

## Versioning Conventions

`dssatengine` adheres to Semantic Versioning (SemVer) with the following specific rules:

- **Patch releases (v0.x.Y)**: Bug fixes, performance improvements, and documentation updates. No changes to public API signatures or behaviors.
- **Minor releases (v0.X.0)**: New features, new exported functions, or backward-compatible modifications to existing capabilities.
- **Major releases (v1.0.0+)**: Breaking changes to the public API, removal of deprecated components, or significant design overhauls.

---

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
