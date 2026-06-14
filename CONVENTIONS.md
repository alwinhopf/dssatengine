# Workspace Conventions & Consolidation Roadmap

Shared conventions for the DSSAT crop-modeling repos, plus the status of the structural
consolidation work. Items marked **Policy (active)** are in force now; items marked
**Planned** are agreed-upon improvements that have **not yet been executed** because they
require running the DSSAT pipelines to verify behavior is preserved.

---

## 1. Read-only shared dependencies — Policy (active)

`dssatutils` and `DSSAT48` (and `dssat-csm-os`) are **consumed, never edited** by the
application repos. Bug fixes go upstream into the dependency and are released as a new
tag; consumers then bump their pin. See [`DEPENDENCIES.md`](DEPENDENCIES.md).

## 2. Version pinning — Policy (active)

Consumers pin `dssatutils` to a **git tag** (`@vX.Y.Z`), never `main`, a commit SHA, or a
local path. This guarantees a pipeline's behavior can't change until the pin is
deliberately bumped. (Several repos currently violate this — see the inconsistencies list
in [`DEPENDENCIES.md`](DEPENDENCIES.md).)

## 3. R ↔ Python parity — Policy (active)

Several components ship mirrored R and Python implementations with **identical function
names** (`dssatutils`, `dssat_lca_tea`'s `pipeline_*` pairs, the gridded engine). The rule:

- A change to one language's implementation **must** be mirrored in the other in the same
  change set, or explicitly documented as language-specific.
- Where a numerical reference exists (e.g. camelina's Excel workbooks), keep a **parity
  test** that asserts both implementations agree with the reference
  (`dssat_lca_tea/test_excel_parity.{py,R}` is the template to follow).
- New shared functionality should add a cross-language parity check rather than relying on
  manual review.

## 4. Repository naming — Policy (active for new repos)

New repositories use **`snake_case`** with no spaces (e.g. `dssat_lca_tea`,
`dssatutils`). Spaces in folder names break shell globs, `cd`, and many scripts.

**Existing space-named repos are NOT auto-renamed.** Renaming
(`DSSAT_Gridded_Run_Tutorial` → `dssat_gridded_run_tutorial`, etc.) is deferred to a
deliberate, verified migration because:

- Cross-repo references exist by path (e.g. consumer scripts reference
  `../DSSAT_Gridded_Run_Tutorial/`; `dssat_lca_tea/dssat_to_lca.{py,R}`; the HPC SLURM
  scripts; `dssatutils/migrate/*.sh`). All would need simultaneous updating.
- The repos are independent git checkouts with their own remotes, RStudio projects, and
  the user's local terminal/IDE state — a rename touches the environment, not just files.

**Migration recipe (when executed):** rename the folder → `grep -rl "<old name>"` across
all repos → update every reference → re-run each repo's smoke tests / a small pipeline
run → commit per repo. Do one repo at a time.

## 5. `.gitignore` hygiene — Policy (active)

Every repo ignores transient/machine state: `__pycache__/`, `*.pyc`, `.DS_Store`,
`.Rhistory`, `.RData`, `.Rproj.user/`, run-scratch dirs (`dssat_runs/`, `run_*`),
acquisition caches (`*_cache/`, `*_netcdf_cache/`, `SoilGrids/`), generated outputs
(`results/`, `visualization/`, `gridpoints/`), and any `.migration_backup_*/` dirs.

> Note: this only stops *future* commits of such files. Files already tracked must be
> removed deliberately with `git rm --cached` inside the relevant repo after confirming
> they aren't intended artifacts — not done automatically here.

---

## Planned consolidation (not yet executed)

These are the high-leverage structural improvements. Each one rewires multiple repos and
**must be verified by running the DSSAT pipelines** (DSSAT binary + data-source API
access + R/Python envs), so they are documented here as a roadmap rather than applied
blind.

### P1 — Extract the gridded engine into a versioned package ✅ DONE
The canonical engine was extracted into the **`dssatengine`** package (R + Python,
v0.1.0), exactly as `dssatutils` was. `DSSAT_Gridded_Run_Tutorial` and
`DSSAT-SubField-MILP-Analysis` now import it as thin wrappers (zero local engine defs);
`Bioenergy` references it via `ENGINE_DIR`.
`dssat_main_pipeline.{R,py}` is no longer hand-copied, so a fix lands once and reaches
every consumer (e.g. the leading-space `DSSBatch` fix). **Remaining:** version-tag the
package so consumers can pin it (currently imported from source / editable install).

### P2 — Centralize `dssat_templates/`
The same genotype files (`.CUL/.ECO/.SPE/.CDE`) are duplicated across most repos and must
be hand-synced (e.g. the cereal-rye `TKFH = -25 °C` ecotype). **Plan:** resolve stock
genotypes from `DSSAT48` via `DSSATPRO.V48`, keep only project-specific FileX/cultivars
local. **Risk:** medium — pipelines read templates by relative path.

### P3 — Promote shared output parsing
The DSSAT output parser (keep `Summary.OUT`, merge to one CSV) is reimplemented per fork.
**Plan:** fold it into the `dssatengine` package (P1) so the I/O-suppression work in
the acceleration experiments is shared, not re-derived. **Risk:** medium — couples to P1.

### P4 — `DSSAT_LAI_Assimilation` removed ✅
The empty placeholder repo is no longer in the workspace checkout; no action remaining.

**Recommended order:** P4 (done) → P2 → P1 → P3, doing one consumer repo at a time with a
verification run between each step.
