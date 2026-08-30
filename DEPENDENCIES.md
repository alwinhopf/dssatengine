# Dependency Pins

This file records **which version of each shared dependency every repo actually uses**,
so results are reproducible and upgrades are deliberate. Re-verify whenever a `dssatutils`
tag is bumped or a consumer is updated.

> **Last verified:** 2026-08-11 (by inspection of `requirements.txt`, `environment.yml`, `renv.lock`, `config.R`,
> `pyproject.toml`, `DESCRIPTION`).

## Shared dependencies

| Dependency | Kind | Current version |
|---|---|---|
| `DSSAT48/dscsm048` | Compiled binary | DSSAT-CSM v4.8 (install in `DSSAT48/`) |
| `dssat_csm_os` | Fortran source | open-source DSSAT-CSM tree (separate checkout) |
| `dssatutils` | R + Python package | `0.5.0` (`pyproject.toml` + `DESCRIPTION`) |
| `dssatengine` | R + Python package | `0.4.1` (`pyproject.toml` + `DESCRIPTION`) |

## How each consumer pins `dssatutils`

| Repo | Language | Pin mechanism | Pinned to |
|---|---|---|---|
| DSSAT_Gridded_Run_Tutorial | Python | `environment.yml` git URL + `conda_lock.yml` resolved commits | `dssatutils@e9c859fa...`; `dssatengine@2280b119...` |
| DSSAT_Gridded_Run_Tutorial | R | `setup_renv.R` / `renv.lock` | `dssatutils@e9c859fa...`; `dssatengine@2280b119...`; `USE_LOCAL_SHARED_PACKAGES=1` opts into sibling checkouts for development |
| DSSAT_SubField_MILP_Analysis | Python | `requirements.txt` git URL | `dssatutils@e9c859fa...`; `dssatengine@2280b119...` |
| DSSAT_ML_Phenology_Prediction | R | `config.R` -> `DSSATUTILS_PATH` / `remotes::install_git` | `@v0.1.0` fallback |
| Bioenergy_Model_Input_Comparison | R | `setup_renv.R` / `renv.lock` | `dssatutils@e9c859fa...`; `dssatengine@2280b119...` |
| Bioenergy_Model_Input_Comparison | Python | via gridded engine / `ENGINE_DIR` | follows selected gridded-engine environment |
| dssat_lca_tea | — | **does not import `dssatutils`** — consumes DSSAT output CSVs | n/a |
| dssatcalibrator / cropmodelcalibrator | Python + R | `pyproject.toml` optional extras / `DESCRIPTION` Remotes | `dssatutils@e9c859fa...`; `dssatengine@2280b119...` |
| pythia | — | independent third-party DSSAT tool (not a consumer of the shared layers) | n/a |

## Pinning policy

Consumers should pin shared workspace packages to an immutable release tag or full
commit SHA, not `main` or an editable sibling path. Editable local installs are fine
for development, but publication or handoff environments must record the resolved
commit in the relevant lockfile. The current shared baseline is:

- `dssatutils`: `e9c859fa1d915623df23e2eb13084cb085dbfe3e`
- `dssatengine`: `2280b11977ad373b9ae19d2d4497e8f276f7b133`

After changing `dssatutils` or `dssatengine`, commit and push the shared-layer change,
then update every consumer pin and lockfile together.

## Python library versions

Pinned identically in the engine and SubField `requirements.txt`
(`numpy==1.26.4`, `pandas==2.2.2`, `geopandas==0.14.4`, `xarray==2024.6.0`,
`netCDF4==1.6.5`, `mpi4py==3.1.6`, …). SubField adds `pyomo==6.7.3` + `highspy==1.7.2`
(MILP) and `scikit-learn==1.5.0` (K-Means zones). See each repo's `requirements.txt` for
the authoritative list.
