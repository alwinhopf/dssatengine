# dssatengine

Shared **gridded DSSAT run engine** — the reusable core of the spatial pipeline,
extracted into one versioned package so the same logic no longer has to be hand-copied
and edited in every consumer repo. Mirror in spirit of [`dssatutils`](../dssatutils)
(which owns weather/soil acquisition); `dssatengine` owns the **build → run → parse**
core that turns grid points + templates into a tidy results table.

> **Private package.** Same R + Python dual-language layout and versioning policy as
> `dssatutils`. See the workspace [`ARCHITECTURE.md`](../ARCHITECTURE.md) and
> [`CONVENTIONS.md`](../CONVENTIONS.md) (item P1).

## What's inside

Python (`python/dssatengine/engine.py`) and R (`R/engine.R`) expose the same core
functions:

| Function | Purpose |
|---|---|
| `create_grid_points` | Build a regular grid of points inside a boundary polygon (Albers). |
| `load_existing_points` | Load/normalize a user point shapefile (centroids, IDs). |
| `extend_weather_repeat_single_ignore_partial` | Extend a `.WTH` series to a target year by climatological repeat. |
| `_write_dssbatch` / `_write_dssbatch_sequence` | Write `DSSBatch.V48` for experiment / sequence runs. |
| `_run_dssat` | Invoke the `dscsm048` binary in a run folder. |
| `_read_csv_safe` / `_merge_supplemental` | Read DSSAT CSV outputs; join `soilorg`/`soilni`/`soilwat` summaries. |
| `_build_result_rows` | Assemble the canonical result schema (yield, SOC Δ, irrigation, N, CO₂/N₂O). |
| `_run_simulation` / `_run_one_point` | Run one point end-to-end (experiment **or** sequence mode) and return results. |

All run/IO functions are **fully parameterized** (executable path, template, treatment
range, years, etc. are arguments) — they do not read pipeline-level config globals, so a
consumer's settings are never silently overridden by package defaults.

### Experiment vs. sequence treatment labeling

`_build_result_rows(..., is_sequence=False)` labels treatments differently per mode:

- **Experiment (mode-A):** DSSAT reports `TRNO == 1` for every treatment, so `RUNNO`
  (which increments 1..N) is used as the treatment id.
- **Sequence (mode-Q, `is_sequence=True`):** each call handles a single treatment, so
  `TRNO` is legitimately constant and is preserved as-is. `_run_simulation` passes
  `is_sequence=True` automatically in the sequence branch.

The R engine labels by `TRNO` directly in both branches (it has no RUNNO override), so
the two languages agree on sequence-mode labeling.

## Consumers

- [`DSSAT Gridded Run Tutorial`](../DSSAT%20Gridded%20Run%20Tutorial) — the engine's origin.
- [`DSSAT SubField MILP Analysis`](../DSSAT%20SubField%20MILP%20Analysis) — sequence/rotation cover-crop runs.

Both import the engine (`library(dssatengine)` / `from dssatengine import …`) instead of
carrying a forked `dssat_main_pipeline`.

## Install / pin

Python consumers currently use an editable local install (`-e ../dssatengine`).
**Planned:** commit, push, and tag the package, then pin consumers to a git tag
(`dssatengine @ git+https://github.com/alwinhopf/dssatengine.git@vX.Y.Z`) — the same
release workflow `dssatutils` uses.
