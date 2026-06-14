# Dependency Pins

This file records **which version of each shared dependency every repo actually uses**,
so results are reproducible and upgrades are deliberate. Re-verify whenever a `dssatutils`
tag is bumped or a consumer is updated.

> **Last verified:** 2026-06-13 (by inspection of `requirements.txt`, `environment.yml`, `config.R`,
> `pyproject.toml`, `DESCRIPTION`).

## Shared dependencies

| Dependency | Kind | Current version |
|---|---|---|
| `DSSAT48/dscsm048` | Compiled binary | DSSAT-CSM v4.8 (install in `DSSAT48/`) |
| `dssat-csm-os` | Fortran source | open-source DSSAT-CSM tree (separate checkout) |
| `dssatutils` | R + Python package | `0.1.0` (`pyproject.toml` + `DESCRIPTION`) |
| `dssatengine` | R + Python package | `0.1.0` (`pyproject.toml` + `DESCRIPTION`) |

## How each consumer pins `dssatutils`

| Repo | Language | Pin mechanism | Pinned to |
|---|---|---|---|
| DSSAT_Gridded_Run_Tutorial | Python | `environment.yml` git URL | `dssatutils@v0.1.0`, `dssatengine@v0.1.0` |
| DSSAT_Gridded_Run_Tutorial | R | `setup_renv.R` / `renv.lock` | GitHub package ref recorded by `renv` |
| DSSAT_SubField_MILP_Analysis | Python | `requirements.txt` git URL | `dssatutils@v0.1.0`, `dssatengine@v0.1.0` |
| DSSAT_ML_Phenology_Prediction | R | `config.R` -> `DSSATUTILS_PATH` / `remotes::install_git` | `@v0.1.0` fallback |
| Bioenergy_Model_Input_Comparison | Python + R | via gridded engine / local sibling fallback | follows gridded engine pins |
| dssat_lca_tea | — | **does not import `dssatutils`** — consumes DSSAT output CSVs | n/a |
| DSSAT_Calibration | — | **does not use `dssatutils`** — own DSSAT wrapper via `DSSAT`/`CroptimizR` | n/a |
| DSSAT_acceleration | Python | imports `dssatutils` as read-only dependency | (pin per `ACCELERATION_PLAN.md`) |

## Pinning policy

Consumers should pin shared workspace packages to a release tag (`@v0.1.0`), not
`main` or an editable sibling path. Editable local installs are fine for development,
but publication or handoff environments should record the tag or resolved commit in
the relevant lockfile.

## Python library versions

Pinned identically in the engine and SubField `requirements.txt`
(`numpy==1.26.4`, `pandas==2.2.2`, `geopandas==0.14.4`, `xarray==2024.6.0`,
`netCDF4==1.6.5`, `mpi4py==3.1.6`, …). SubField adds `pyomo==6.7.3` + `highspy==1.7.2`
(MILP) and `scikit-learn==1.5.0` (K-Means zones). See each repo's `requirements.txt` for
the authoritative list.
