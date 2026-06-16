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

## 6. Cross-Platform & Failsafe Standards — Policy (active)

To guarantee that crop modeling workflows execute correctly and deterministically on developer workstations (Windows/macOS), server containers (Linux), and HPC clusters, all code must follow these standards.

> [!NOTE]
> **Pythia Exclusion:** The third-party repository `pythia` is explicitly excluded from these standards as it is treated as a read-only vendored dependency.

### Canonical environment variables

These are the workspace-standard variable names. Use them in config files and
documentation; never hardcode the paths they represent.

| Variable | Purpose |
|---|---|
| `DSSAT_EXE` | Path to the compiled `dscsm048` / `dscsm048.exe` binary. |
| `DSSAT_DIR` | Root of the DSSAT48 install (databases, crop coefficients). |
| `ENGINE_DIR` | Path to the `dssatengine` package checkout (sibling-path consumers). |
| `MILP_MODEL_DIR` | Path to the SubField MILP model directory. |
| `DSSATUTILS_PATH` | Path to the `dssatutils` checkout (R `remotes::install_git` fallback). |

### A. Path Handling & Operations
1. **Never Hardcode Separators:** Do not construct paths using string concatenation or hardcoded slashes (like `\` or `/`).
   - **Python:** Prefer `pathlib.Path` objects and the `/` operator for new code. `os.path.join()` / `os.path.exists()` are acceptable alternatives — the key rule is never to concatenate path strings manually or hardcode separators.
     ```python
     # Good (preferred)
     from pathlib import Path
     data_path = Path("data") / "weather" / "station.WTH"

     # Acceptable
     import os
     data_path = os.path.join("data", "weather", "station.WTH")

     # Bad — hardcoded separator
     data_path = "data\\weather\\station.WTH"
     ```
   - **R:** Use `file.path()` or the `fs` package. Always use forward slashes `/` for literal path components in R code (even on Windows).
     ```R
     # Good
     data_path <- file.path("data", "weather", "station.WTH")
     ```
2. **Absolute Path Resolution:** Use absolute paths when passing file/directory arguments to spawned subprocesses to prevent working directory confusion.
   - **Python:** `path_obj.resolve()`
   - **R:** `normalizePath(path_str, mustWork = FALSE)`
3. **Case Sensitivity:** Filenames and paths must be treated as case-sensitive at all times, since code will run on Linux filesystems. Always match the exact casing of DSSAT files (e.g., `Summary.OUT`, `ERROR.OUT`, `DSSBatch.V48`).
4. **Temporary Directories:** Write transient files only inside official system temporary directories (`tempdir()` in R, `tempfile.TemporaryDirectory` in Python) or designated local git-ignored caches. Clean them up on exit.

### B. External Binary Spawning (Running DSSAT)
1. **Dynamic Executable Resolving:** The DSSAT compiled executable is named `dscsm048.exe` on Windows and `dscsm048` on Linux/macOS. Code must dynamically resolve the name or expect it via config/environment variables.
2. **No Shell Invocations:** Never invoke command strings through a shell environment (e.g. `shell=True` in Python or `system()` in R) as this introduces platform syntax inconsistencies and security vulnerabilities.
   - **Python:** Pass commands as a list of strings:
     ```python
     import subprocess
     result = subprocess.run([exe_path, run_mode, batch_file], check=True, capture_output=True, text=True)
     ```
   - **R:** Pass arguments as a character vector to `system2()`:
     ```R
     status <- system2(exe_path, args = c(run_mode, batch_file), stdout = "stdout.log", stderr = "stderr.log")
     if (status != 0) stop("DSSAT failed with exit code ", status)
     ```
3. **Capture & Validate Exit Codes:** Spawning processes must always check the return status. A non-zero exit status must throw an informative error (including logs tail if possible) and abort the pipeline execution.
4. **Standard Output/Error Safety:** Capture stdout and stderr to logs or redirect them to `/dev/null` (or platform equivalent) to prevent stdout buffers from filling up and hanging the program.

### C. Concurrency & Parallelization
1. **Python Spawn Guard:** All Python script entry points using parallel/multiprocessing libraries must be protected with `if __name__ == '__main__':` to prevent infinite recursion loop crashes when using the `spawn` process start method on Windows.
2. **R Parallel Portability:** Avoid `mclapply()` or forked clusters in R since they are not supported on Windows. Instead, use socket-based parallel clusters (`parallel::makeCluster()`) or package abstracts like `foreach` with `doParallel`, or `pbapply::pblapply` with socket clusters.
3. **Race Condition Prevention:** Ensure concurrent processes write their outputs to unique, separated directory namespaces (e.g., `run_000001/`, `run_000002/`) to avoid file collision bugs.

### D. File I/O & Encodings
1. **Explicit Encoding:** Always read and write text files using explicit UTF-8 encoding to avoid failures on machines with different active system codepages.
   - **Python:** `open(filepath, "r", encoding="utf-8")`
   - **R:** `readLines(filepath, encoding="UTF-8")`
2. **Line Endings:** Be tolerant of Windows carriage returns (`\r\n`) when parsing DSSAT input/output files on Linux, and output Unix standard LF (`\n`) line endings in written files.
3. **Floating Point Comparison:** Parity validations must never compare floats using exact equality (`==`). Use tolerances for comparisons:
   - **Python:** `math.isclose(a, b, rel_tol=1e-6)` or `numpy.allclose(a, b)`
   - **R:** `all.equal(a, b, tolerance = 1e-6)`

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
