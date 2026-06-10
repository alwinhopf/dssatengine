# DSSAT Crop-Modeling Workspace

This directory is a collection of independent git repositories that together form a
**DSSAT (Decision Support System for Agrotechnology Transfer) crop-modeling stack** —
a compiled crop model, a shared data-download library, a reusable gridded-simulation
engine, and several specialized scientific applications built on top.

> **New here? Start with [`ARCHITECTURE.md`](../DSSAT_Gridded_Run_Tutorial/ARCHITECTURE.md)**
> (the single canonical copy, kept in `DSSAT_Gridded_Run_Tutorial/`) for how the pieces
> fit together, then [`DEPENDENCIES.md`](DEPENDENCIES.md) for what each repo pins, and
> [`CONVENTIONS.md`](CONVENTIONS.md) for the shared coding/structure conventions.

## Repository index

| Repo | Tier | Language | Purpose |
|---|---|---|---|
| [`DSSAT48`](DSSAT48) | Foundation | Fortran (binary) | Compiled DSSAT-CSM v4.8 install: `dscsm048` binary, crop genotype files, code definitions. Read-only. |
| [`dssat-csm-os`](dssat-csm-os) | Foundation | Fortran (source) | DSSAT-CSM open-source source tree (CMake build). The compilable counterpart to `DSSAT48`. |
| [`dssatutils`](dssatutils) | Foundation | R + Python | Shared weather/soil download library → `.WTH` / `.SOL`. Private package, version-pinned by consumers. |
| [`DSSAT_Gridded_Run_Tutorial`](DSSAT_Gridded_Run_Tutorial) | **Engine** | R + Python | Canonical gridded pipeline: points → weather+soil → FileX → run → parse. Includes the HPC MPI runner. |
| [`Bioenergy_Model_Input_Comparison`](Bioenergy_Model_Input_Comparison) | Application | Python + R | Compares weather × soil data-source choices on carinata model outputs. |
| [`dssat_lca_tea`](dssat_lca_tea) | Application | Python + R | LCA/TEA pipeline for camelina/carinata sustainable aviation fuel (consumes DSSAT yields). |
| [`DSSAT_Calibration`](DSSAT_Calibration) | Application | R (`dssatcal`) | AgMIP-protocol genotype calibration with sensitivity screening + Bayesian UQ. |
| [`DSSAT_ML_Phenology_Prediction`](DSSAT_ML_Phenology_Prediction) | Application | R | 22-model hybrid winter-wheat phenology pipeline (physics + assimilation + ML/DL). |
| [`DSSAT_SubField_MILP_Analysis`](DSSAT_SubField_MILP_Analysis) | Application | Python + R | Subfield cover-crop bioenergy modeling + MILP placement optimization. |
| [`DSSAT_acceleration`](DSSAT_acceleration) | Application | Python | Standalone performance pipeline (HRU dedup, output suppression, RAM-disk batching) for 30 m / continental scale. |
| [`DSSAT_LAI_Assimilation`](DSSAT_LAI_Assimilation) | Application | — | Planned LAI remote-sensing data-assimilation study (scaffold only). |

## Conventions at a glance

- Each subfolder is its **own git repository**; this top-level directory is not tracked.
- `dssatutils`, `DSSAT48`, and `dssatengine` are the **read-only shared dependencies** —
  consume, don't edit.
- The gridded engine is now extracted into the shared **`dssatengine`** package; the
  pipeline repos import it rather than carrying hand-copied forks.
- See [`CONVENTIONS.md`](CONVENTIONS.md) for naming, R↔Python parity, `.gitignore`
  hygiene, and the remaining consolidation roadmap (templates, shared parsing, parity).
