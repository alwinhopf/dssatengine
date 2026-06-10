# Dependency Pins

This file records **which version of each shared dependency every repo actually uses**,
so results are reproducible and upgrades are deliberate. Re-verify whenever a `dssatutils`
tag is bumped or a consumer is updated.

> **Last verified:** 2026-06-09 (by inspection of `requirements.txt`, `config.R`,
> `pyproject.toml`, `DESCRIPTION`).

## Shared dependencies

| Dependency | Kind | Current version |
|---|---|---|
| `DSSAT48/dscsm048` | Compiled binary | DSSAT-CSM v4.8 (install in `DSSAT48/`) |
| `dssat-csm-os` | Fortran source | open-source DSSAT-CSM tree (separate checkout) |
| `dssatutils` | R + Python package | `0.1.0` (`pyproject.toml` + `DESCRIPTION`) |

## How each consumer pins `dssatutils`

| Repo | Language | Pin mechanism | Pinned to |
|---|---|---|---|
| DSSAT_Gridded_Run_Tutorial | Python | `requirements.txt` git URL | commit `08c9810a…` |
| DSSAT_Gridded_Run_Tutorial | R | `renv.lock` / `DSSATUTILS_PATH` auto-detect | local source |
| DSSAT_SubField_MILP_Analysis | Python | `requirements.txt` editable install | `-e /Users/alwinhopf/Documents/GitHub/dssatutils` (local, machine path) |
| DSSAT_ML_Phenology_Prediction | R | `config.R` → `DSSATUTILS_PATH` / `remotes::install_local` | local source |
| Bioenergy_Model_Input_Comparison | Python + R | (inherits engine fork) | local source |
| dssat_lca_tea | — | **does not import `dssatutils`** — consumes DSSAT output CSVs | n/a |
| DSSAT_Calibration | — | **does not use `dssatutils`** — own DSSAT wrapper via `DSSAT`/`CroptimizR` | n/a |
| DSSAT_acceleration | Python | imports `dssatutils` as read-only dependency | (pin per `ACCELERATION_PLAN.md`) |

## ⚠️ Inconsistencies to resolve

The `dssatutils` README states the policy is **"consumers always pin to a tag (`@v0.1.0`),
never `main` or a commit."** The current state does not match that policy:

1. **Gridded (Python)** pins a **commit SHA** (`08c9810a…`), not a tag. → Re-pin to `@v0.1.0`.
2. **SubField (Python)** uses an **editable local install** with an **absolute machine path**
   (`-e /Users/alwinhopf/…`). This is not reproducible on another machine and is not version
   pinned. → Replace with the tagged git URL.
3. **R consumers** install from **local source** (`install_local` / `DSSATUTILS_PATH`), which
   tracks whatever is checked out rather than a tag. → Pin via `renv` to the tagged ref.

Aligning all four to `@v0.1.0` (and tagging `dssatutils` if `0.1.0` is not yet a git tag)
would make every pipeline reproducible from a clean checkout.

## Python library versions

Pinned identically in the engine and SubField `requirements.txt`
(`numpy==1.26.4`, `pandas==2.2.2`, `geopandas==0.14.4`, `xarray==2024.6.0`,
`netCDF4==1.6.5`, `mpi4py==3.1.6`, …). SubField adds `pyomo==6.7.3` + `highspy==1.7.2`
(MILP) and `scikit-learn==1.5.0` (K-Means zones). See each repo's `requirements.txt` for
the authoritative list.
