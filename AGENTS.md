# AGENTS.md — dssatengine

> **Workspace context:** Read the root [`../AGENTS.md`](../AGENTS.md) first. This document
> holds rules and guidance specific to the `dssatengine` repository.

## 1. Role in the Workspace

`dssatengine` is the **canonical gridded DSSAT-CSM execution and parsing library**:
- It encapsulates grid-point creation (including master-grid lattice subsets), FileX preparation, `DSSBatch.V48` creation, DSSAT process spawning, and `.OUT` / `.CSV` parsing.
- It is consumed by `DSSAT_Gridded_Run_Tutorial`, `DSSAT_SubField_MILP_Analysis`, `dssatcalibrator`, and `Bioenergy_Model_Input_Comparison`.
- Application repos must **never** fork or re-implement this logic locally.

## 2. 1:1 R ↔ Python Parity Contract

`dssatengine` is a dual-language package:
- R implementation: `R/engine.R`, `R/parser.R`, `R/zzz.R` (package namespace exported via `NAMESPACE`).
- Python implementation: `python/dssatengine/engine.py`, `python/dssatengine/output_parser.py`, `python/dssatengine/__init__.py`.
- **Any bug fix, new parser, or feature in one language must be added to the twin in the exact same edit**, with identical public function names and output schemas.

### Public API Surface
- Grid generation: `create_grid_points`, `create_master_grid_points`, `derive_nested_grid_points`, `load_existing_points`.
- Weather repetition: `extend_weather_repeat_single_ignore_partial`.
- Batch & Execution: `normalize_treatment_list`, `write_dssbatch`, `write_dssbatch_sequence`, `run_dssat`, `run_simulation`.
- Output Parsers: `parse_timeseries` (aliases `parse_plantgro`, `parse_plantn`), `parse_summary`, `parse_evaluate`, `parse_csv`, `parse_dssat_output`, `read_run_directory`, `yyddd_to_date`.
- Schema Constants: `LAT_COLUMN`, `LONG_COLUMN`, `POINT_ID_COLUMN`, `MASTER_ROW_COLUMN`, `MASTER_COL_COLUMN`, `MASTER_SPACING_COLUMN`.

## 3. Critical Implementation Rules & Common Pitfalls

### A. `DSSBatch.V48` Column Alignment
- In `DSSBatch.V48`, the FileX field **must start at column 1** (no leading whitespace).
- A leading space causes Fortran `CSM.for` to compute a negative substring index and crash with `Substring out of bounds`.

### B. Fail-Loud Execution & Error Logging
- `run_dssat` must check the exit code of `dscsm048`.
- If non-zero or if DSSAT crashes, write stdout/stderr to `_run_error.log`, inspect `WARNING.OUT` and `ERROR.OUT`, and raise a descriptive error including the log file path. Never swallow failures silently.

### C. Output Parser Resilience
- **Fortran Asterisks (`****`):** Convert numeric overflow asterisks to `NaN` / `NA` without crashing the parser.
- **Missing Value Codes:** Map `-99` and `-99.0` sentinel codes to `NaN` / `NA`.
- **Scientific Notation & Irregular Spacing:** Handle floats with exponents (`1.23E+02`) and space-separated text columns (`TNAM`, `FNAM`, `MODEL`) using fixed-width or robust regex parsing.
- **Sequence Simulations (`.SQX`):** Rotation phases may simulate different crops with different column headers. Parsers must preserve each block's header, concatenate by column name, and tag each row with `rotation` and `crop_model`.

### D. Working Directory Isolation & Genotype Immutability
- Simulations must execute inside isolated per-point run directories (`dssat_runs/<point_id>`).
- Never overwrite or modify genotype files (`.CUL`, `.ECO`, `.SPE`) in the global `DSSAT48` directory. Copy mutable files into the run folder first.

## 4. Verification & Testing

Both test suites must pass before finishing an edit:

```bash
# Python pytest
pytest tests/

# R testthat
Rscript -e "testthat::test_dir('tests/testthat')"
```
