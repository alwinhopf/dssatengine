"""Parsers for DSSAT-CSM output files (the ``run → parse`` half of the engine).

DSSAT writes two families of result files:

* **Daily time-series** (``PlantGro.OUT``, ``PlantN.OUT``, ``PlantGr2.OUT``,
  ``MgmtOps.OUT``, ``GHG.OUT``, ``SoilWat.OUT``, ``ET.OUT``, ``Weather.OUT`` …).
  Each is a sequence of *run blocks*: a ``*RUN`` line, free-text metadata, a
  single ``@YEAR DOY …`` column header, then whitespace-delimited numeric rows.
  All of these share one structure, so :func:`parse_timeseries` reads any of them.
* **Summary / scalar** files (``Summary.OUT``, ``Evaluate.OUT``). ``Summary.OUT``
  is fixed-width because ``TNAM``/``FNAM`` contain spaces, so it is parsed by
  header column positions (:func:`parse_summary`). ``Evaluate.OUT`` pairs
  simulated vs. measured scalars (:func:`parse_evaluate`).

DSSAT's ``FMOPT='C'`` option additionally writes CSV twins (``summary.csv``,
``plantgro.csv``); :func:`parse_csv` reads those with the same missing-value and
date conventions so callers get an identical frame either way.

**Sequence (.SQX) vs. experiment (.??X).** In a *sequence* simulation each
``*RUN`` block can be a different crop in the rotation, so consecutive blocks may
carry *different* ``@`` headers (different columns). The block reader keeps each
block's own header and concatenates by column name (missing columns become NaN),
and every row carries ``run``, ``treatment``, ``crop_model`` and ``rotation``
identifiers so rotation phases stay separable. Experiment runs simply have one
block per treatment with a shared header.

The sentinel ``-99`` / ``-99.0`` is DSSAT's missing-data marker and is mapped to
``NaN`` throughout.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Optional, Union

import numpy as np
import pandas as pd

MISSING = -99.0

# Files that are NOT row/column tables (free-text reports, narrative per-timestep
# balances, run lists). read_run_directory skips these. Note the per-season balance
# *summaries* (SWBalSum, SoilCBalSum, SoilNBalSum) ARE tabular (one row per run) and
# are deliberately NOT listed here; only the narrative per-timestep `*Bal` files are.
_NON_TABULAR = {
    "info.out", "version.out", "runlist.out", "warning.out", "error.out",
    "soilnibal.out", "soilnobal.out", "soilwatbal.out", "soilcbal.out",
    "overview.out", "measured.out",
}

PathLike = Union[str, "os.PathLike[str]"]


# --------------------------------------------------------------------------- #
#  Shared helpers                                                             #
# --------------------------------------------------------------------------- #
def yyddd_to_date(code) -> pd.Timestamp:
    """Convert a DSSAT ``YYDDD`` or ``YYYYDDD`` date code to a Timestamp.

    Two-digit years < 80 read as 20xx, otherwise 19xx (DSSAT convention).
    Returns ``NaT`` for missing / unparseable / out-of-range codes.
    """
    try:
        s = str(int(float(code))).strip()
    except (ValueError, TypeError):
        return pd.NaT
    if s in ("", "-99", "0"):
        return pd.NaT
    if len(s) <= 5:                      # YYDDD
        s = s.zfill(5)
        yy, doy = int(s[:2]), int(s[2:])
        year = 2000 + yy if yy < 80 else 1900 + yy
    else:                                # YYYYDDD
        s = s.zfill(7)
        year, doy = int(s[:4]), int(s[4:])
    max_doy = 366 if pd.Timestamp(year=year, month=12, day=31).dayofyear == 366 else 365
    if doy < 1 or doy > max_doy:
        return pd.NaT
    return pd.Timestamp(year=year, month=1, day=1) + pd.Timedelta(days=doy - 1)


def _to_numeric(df: pd.DataFrame, columns=None) -> pd.DataFrame:
    """Coerce columns to numeric where possible and map the -99 sentinel to NaN.

    Non-numeric columns (e.g. text identifiers) are left untouched.
    """
    out = df.copy()
    cols = columns if columns is not None else out.columns
    for c in cols:
        coerced = pd.to_numeric(out[c], errors="coerce")
        # Only replace the column if it is meaningfully numeric (avoid nuking a
        # genuine text column whose every value coerces to NaN).
        if coerced.notna().any() or out[c].isna().all():
            out[c] = coerced.mask(np.isclose(coerced, MISSING))
    return out


def _add_date_from_year_doy(df: pd.DataFrame) -> pd.DataFrame:
    """Add a ``date`` column derived from YEAR + DOY when both are present."""
    if {"YEAR", "DOY"}.issubset(df.columns):
        yr = pd.to_numeric(df["YEAR"], errors="coerce").astype("Int64")
        doy = pd.to_numeric(df["DOY"], errors="coerce").astype("Int64")
        df["date"] = pd.to_datetime(
            yr.astype("string") + "-" + doy.astype("string"),
            format="%Y-%j", errors="coerce",
        )
    return df


# --------------------------------------------------------------------------- #
#  Daily time-series files (PlantGro.OUT, PlantN.OUT, MgmtOps.OUT, GHG.OUT …)  #
# --------------------------------------------------------------------------- #
_RUN_RE = re.compile(r"\*RUN\s+(\d+)")
_TRT_RE = re.compile(r"\s*TREATMENT\s+(\d+)")
_MODEL_RE = re.compile(r"\s*MODEL\s*:\s*(\S+)")


def _iter_run_blocks(lines: list[str]):
    """Yield ``(run_no, meta, header, rows)`` for each ``*RUN`` block.

    ``meta`` carries the per-block identifiers parsed from the free-text preamble
    (``treatment``, ``crop_model``, ``run_label``). ``header`` is the column-name
    list from the block's ``@`` line; ``rows`` is the list of split data rows.
    A file with no ``*RUN`` marker is treated as a single implicit block (run 1),
    which makes single-run files and oddly-formatted files both parse.
    """
    run_no = None
    meta = {"treatment": None, "crop_model": None, "run_label": None}
    header: Optional[list[str]] = None
    rows: list[list[str]] = []
    seen_block = False

    def emit():
        if header is not None and rows:
            return (run_no, dict(meta), header, list(rows))
        return None

    for ln in lines:
        if ln.startswith("*RUN"):
            blk = emit()
            if blk:
                yield blk
            seen_block = True
            m = _RUN_RE.match(ln)
            run_no = int(m.group(1)) if m else None
            # Reset per-block metadata; the trailing token on a *RUN line is the
            # crop-model code (e.g. "CSCER048"); the text between is the label.
            meta = {"treatment": None, "crop_model": None, "run_label": None}
            tail = ln.split(":", 1)
            if len(tail) == 2:
                toks = tail[1].split()
                meta["run_label"] = tail[1].strip()
                if toks:
                    # second-to-last is often the model when an exp id trails it
                    for t in toks:
                        if re.match(r"^[A-Z]{2}[A-Z0-9]{3}\d{3}$", t):
                            meta["crop_model"] = t
                            break
            header = None
            rows = []
        elif ln.lstrip().startswith("MODEL") and ":" in ln:
            m = _MODEL_RE.match(ln)
            if m and not meta.get("crop_model"):
                meta["crop_model"] = m.group(1)
        elif ln.lstrip().startswith("TREATMENT"):
            m = _TRT_RE.match(ln)
            if m:
                meta["treatment"] = int(m.group(1))
        elif ln.startswith("@"):
            # Any '@' line is the block's column header. Most files key on
            # YEAR/DOY/DAS (daily series) but some are keyed differently —
            # Leaves.OUT by leaf number (@ LNUM …), the balance summaries by run
            # (@Run FILEX TN CR …) — so accept any '@' header, not just daily ones.
            raw_header = ln.lstrip("@")
            header = [token.rstrip(".") for token in raw_header.split()]
            # Preserve fixed-width text fields such as Plantsum TNAME instead
            # of shifting every later column with whitespace splitting.
            starts = [m.start() + (len(ln) - len(ln.lstrip("@")))
                      for m in re.finditer(r"\S+", raw_header)]
            meta["header_starts"] = starts
            rows = []
        elif header is not None and re.match(r"\s*-?\d", ln) and not ln.startswith("*"):
            starts = meta.get("header_starts", [])
            if any("TNAME" in h for h in header) and len(starts) == len(header):
                parts = [ln[starts[i]:starts[i + 1]].strip()
                         for i in range(len(starts) - 1)]
                parts.append(ln[starts[-1]:].strip())
            else:
                parts = ln.split()
            if not parts:
                continue
            if len(parts) >= len(header):
                rows.append(parts[: len(header)])
            else:                              # short row -> pad with sentinel
                rows.append(parts + [str(int(MISSING))] * (len(header) - len(parts)))

    if not seen_block:
        run_no = 1
    blk = emit()
    if blk:
        yield blk


def parse_timeseries(path: PathLike, add_date: bool = True) -> pd.DataFrame:
    """Parse any DSSAT daily time-series ``.OUT`` file into a tidy DataFrame.

    Works for ``PlantGro.OUT``, ``PlantN.OUT``, ``PlantGr2.OUT``, ``MgmtOps.OUT``,
    ``GHG.OUT``, ``SoilWat.OUT``, ``ET.OUT``, ``Weather.OUT`` and any other file
    that follows the ``*RUN`` / ``@`` / numeric-rows convention.

    Returns one row per (run, day) with every numeric column from the file plus:
    ``run``, ``treatment`` (falls back to ``run`` when absent), ``crop_model``,
    ``rotation`` (1-based index of the block within the file — distinguishes
    sequence rotation phases), and (when YEAR+DOY exist and *add_date*) ``date``.
    Returns an empty DataFrame for missing files or files with no data block.
    """
    p = Path(path)
    if not p.exists():
        return pd.DataFrame()
    lines = p.read_text(errors="replace").splitlines()

    frames: list[pd.DataFrame] = []
    for rotation, (run_no, meta, header, rows) in enumerate(_iter_run_blocks(lines), start=1):
        df = pd.DataFrame(rows, columns=header)
        df = _to_numeric(df)
        df["run"] = run_no
        df["treatment"] = meta["treatment"] if meta["treatment"] is not None else run_no
        df["crop_model"] = meta["crop_model"]
        df["rotation"] = rotation
        frames.append(df)

    if not frames:
        return pd.DataFrame()
    out = pd.concat(frames, ignore_index=True)   # aligns by column name across blocks
    if add_date:
        out = _add_date_from_year_doy(out)
    out["run"] = pd.to_numeric(out["run"], errors="coerce").astype("Int64")
    out["treatment"] = pd.to_numeric(out["treatment"], errors="coerce").astype("Int64")
    out["rotation"] = out["rotation"].astype("Int64")
    return out


# Convenience aliases for the most-used files (all share parse_timeseries).
def parse_plantgro(path: PathLike) -> pd.DataFrame:
    """Parse ``PlantGro.OUT`` (daily growth) — see :func:`parse_timeseries`."""
    return parse_timeseries(path)


def parse_plantn(path: PathLike) -> pd.DataFrame:
    """Parse ``PlantN.OUT`` (daily plant nitrogen) — see :func:`parse_timeseries`."""
    return parse_timeseries(path)


# --------------------------------------------------------------------------- #
#  Summary.OUT  (fixed-width: TNAM/FNAM/MODEL columns contain spaces)          #
# --------------------------------------------------------------------------- #
def _summary_column_spans(header_line: str) -> list[tuple[str, int, int]]:
    """Return ``(name, start, end)`` character spans for each Summary column.

    DSSAT right-justifies every field to the end column of its header token and
    pads text headers with dots (``TNAM.....``) out to the field width, so a
    field's characters run from the previous field's end to this token's end.
    Slicing by these spans recovers even spacey text columns intact.
    """
    h = " " + header_line[1:] if header_line.startswith("@") else header_line
    spans: list[tuple[str, int, int]] = []
    prev = 0
    for m in re.finditer(r"\S+", h):
        name = m.group(0).rstrip(".")
        spans.append((name, prev, m.end()))
        prev = m.end()
    return spans


def parse_summary(path: PathLike) -> pd.DataFrame:
    """Parse ``Summary.OUT`` into one row per run, every column preserved.

    Columns whose name ends in ``DAT`` (date codes) additionally get a
    ``*_date`` Timestamp twin. Numeric columns are coerced (``-99`` -> NaN);
    text identifiers (``CR``, ``MODEL``, ``EXNAME``, ``TNAM``, ``FNAM``,
    ``WSTA``, ``SOIL_ID``) are kept as trimmed strings. Returns an empty frame
    for a missing file or one with no ``@…RUNNO`` header.
    """
    p = Path(path)
    if not p.exists():
        return pd.DataFrame()
    lines = p.read_text(errors="replace").splitlines()
    hdr_idx = next(
        (i for i, ln in enumerate(lines)
         if ln.lstrip().startswith("@") and "RUNNO" in ln),
        None,
    )
    if hdr_idx is None:
        return pd.DataFrame()

    spans = _summary_column_spans(lines[hdr_idx])
    n = len(spans)
    recs = []
    for ln in lines[hdr_idx + 1:]:
        if not re.match(r"\s*\d", ln):       # data rows start with the run number
            continue
        rec = {}
        for i, (name, s, e) in enumerate(spans):
            end = len(ln) if i == n - 1 else e
            rec[name] = ln[s:end].strip()
        recs.append(rec)
    if not recs:
        return pd.DataFrame()

    df = pd.DataFrame(recs)
    text_cols = {"CR", "MODEL", "EXNAME", "TNAM", "FNAM", "WSTA", "SOIL_ID"}
    num_cols = [c for c in df.columns if c not in text_cols]
    df = _to_numeric(df, columns=num_cols)
    for c in text_cols & set(df.columns):
        df[c] = df[c].astype("string").str.strip()
    for c in [c for c in df.columns if c.endswith("DAT")]:
        df[f"{c}_date"] = df[c].map(yyddd_to_date)
    return df


# --------------------------------------------------------------------------- #
#  Evaluate.OUT  (simulated vs. measured scalars; written when observed data   #
#  are present in the run dir)                                                 #
# --------------------------------------------------------------------------- #
def parse_evaluate(path: PathLike) -> pd.DataFrame:
    """Parse ``Evaluate.OUT`` into a long ``(treatment, run, variable, sim, meas)``
    table. Simulated/measured pairs are detected from the ``…S``/``…M`` suffix
    convention. Returns an empty (typed) frame when the file is absent/empty.
    """
    cols = ["treatment", "run", "variable", "sim", "meas"]
    p = Path(path)
    if not p.exists():
        return pd.DataFrame(columns=cols)
    lines = p.read_text(errors="replace").splitlines()
    hdr_idx = next((i for i, ln in enumerate(lines) if ln.startswith("@RUN")), None)
    if hdr_idx is None:
        return pd.DataFrame(columns=cols)

    header = lines[hdr_idx].lstrip("@").split()
    data = [ln.split() for ln in lines[hdr_idx + 1:] if re.match(r"\s*\d", ln)]
    if not data:
        return pd.DataFrame(columns=cols)
    wide = pd.DataFrame(data, columns=header[: len(data[0])])

    id_cols = {"RUN", "EXCODE", "TRNO", "TN", "RN", "CR"}
    sim_cols = [c for c in wide.columns
                if c.endswith("S") and c[:-1] + "M" in wide.columns and c not in id_cols]

    # DSSAT names the treatment column TRNO (older builds: TN).
    trt_col = "TRNO" if "TRNO" in wide.columns else ("TN" if "TN" in wide.columns else None)
    recs = []
    for _, row in wide.iterrows():
        trt = pd.to_numeric(row.get(trt_col), errors="coerce") if trt_col else np.nan
        run = pd.to_numeric(row.get("RUN"), errors="coerce")
        for sc in sim_cols:
            base = sc[:-1]
            recs.append((
                trt, run, base,
                pd.to_numeric(row[sc], errors="coerce"),
                pd.to_numeric(row[base + "M"], errors="coerce"),
            ))
    out = pd.DataFrame(recs, columns=cols)
    out[["sim", "meas"]] = out[["sim", "meas"]].mask(np.isclose(out[["sim", "meas"]], MISSING))
    out["treatment"] = out["treatment"].astype("Int64")
    out["run"] = out["run"].astype("Int64")
    return out


# --------------------------------------------------------------------------- #
#  CSV twins  (FMOPT='C': summary.csv, plantgro.csv, …)                        #
# --------------------------------------------------------------------------- #
def parse_csv(path: PathLike, add_date: bool = True) -> pd.DataFrame:
    """Parse a DSSAT ``FMOPT='C'`` CSV twin (``summary.csv``, ``plantgro.csv``).

    Maps ``-99`` -> NaN and, when YEAR+DOY (time-series) or ``*DAT`` (summary)
    columns are present, adds the same derived ``date`` / ``*_date`` columns as
    the ``.OUT`` parsers, so a CSV-mode run is interchangeable with a text run.
    """
    p = Path(path)
    if not p.exists():
        return pd.DataFrame()
    try:
        df = pd.read_csv(p, index_col=False, encoding="utf-8")
    except Exception:
        return pd.DataFrame()
    if df.empty:
        return df
    df = df.mask(df.apply(pd.to_numeric, errors="coerce").apply(lambda s: np.isclose(s, MISSING)))
    if add_date:
        df = _add_date_from_year_doy(df)
        date_cols = {
            f"{c}_date": df[c].map(yyddd_to_date)
            for c in df.columns
            if c.endswith("DAT") and not c.endswith("_date") and f"{c}_date" not in df.columns
        }
        if date_cols:
            df = pd.concat([df, pd.DataFrame(date_cols, index=df.index)], axis=1)
    return df


# --------------------------------------------------------------------------- #
#  Dispatcher + whole-directory reader                                        #
# --------------------------------------------------------------------------- #
def parse_dssat_output(path: PathLike, add_date: bool = True) -> pd.DataFrame:
    """Parse any single DSSAT output file, dispatching on its name/structure.

    ``Summary.OUT`` -> :func:`parse_summary`; ``Evaluate.OUT`` ->
    :func:`parse_evaluate`; ``*.csv`` -> :func:`parse_csv`; everything else is
    treated as a daily time-series (:func:`parse_timeseries`).
    """
    name = os.path.basename(str(path)).lower()
    if name.endswith(".csv"):
        return parse_csv(path, add_date=add_date)
    if name in _NON_TABULAR:
        # Free-text reports / narrative balances / run lists are not data tables
        # (OVERVIEW.OUT embeds '@' blocks but is a human report, not one table).
        return pd.DataFrame()
    if name == "summary.out":
        return parse_summary(path)
    if name == "evaluate.out":
        return parse_evaluate(path)
    return parse_timeseries(path, add_date=add_date)


def read_run_directory(run_dir: PathLike,
                       files: Optional[list[str]] = None,
                       add_date: bool = True,
                       include_csv: bool = True) -> dict[str, pd.DataFrame]:
    """Parse the DSSAT output files in *run_dir* into a name -> DataFrame dict.

    With *files* unset, reads every tabular ``*.OUT`` (skipping balances / run
    lists / free-text reports) plus, when *include_csv* (the default), every
    ``FMOPT='C'`` ``*.csv`` twin — so a CSV-mode run (whose daily data lands in
    ``plantgro.csv`` etc., not ``.OUT``) is read just as fully as a text run.
    When both forms of a file are present (e.g. ``Summary.OUT`` + ``summary.csv``)
    the ``.OUT`` wins and the duplicate ``.csv`` is skipped, so each data table
    appears once. Pass an explicit *files* list (e.g.
    ``["Summary.OUT", "PlantGro.OUT"]`` — the common case) to read only those.
    Keys are the lower-cased file stem (``"plantgro"``, ``"summary"``). Empty
    parses are omitted.
    """
    d = Path(run_dir)
    if not d.is_dir():
        return {}

    if files is not None:
        candidates = list(files)
    else:
        out_files = sorted(f.name for f in d.iterdir()
                           if f.is_file() and f.suffix.lower() == ".out"
                           and f.name.lower() not in _NON_TABULAR)
        candidates = list(out_files)
        if include_csv:
            csv_files = sorted(f.name for f in d.iterdir()
                               if f.is_file() and f.suffix.lower() == ".csv")
            csv_stems = {Path(f).stem.lower() for f in csv_files}
            # CSV is the authoritative output of an FMOPT='C' run. Prefer it
            # over an OUT twin, which may be stale from an earlier ASCII run.
            candidates = [f for f in candidates if Path(f).stem.lower() not in csv_stems]
            candidates += csv_files

    out: dict[str, pd.DataFrame] = {}
    for fname in candidates:
        fpath = d / fname
        if not fpath.exists():
            continue
        df = parse_dssat_output(fpath, add_date=add_date)
        if df is not None and not df.empty:
            out[fpath.stem.lower()] = df
    return out
