import os
import re
import math
import subprocess
import platform
import shutil
from datetime import datetime
from pathlib import Path
from typing import Optional
import numpy as np
import pandas as pd
import geopandas as gpd
from shapely.geometry import Point

LAT_COLUMN = "LAT"
LONG_COLUMN = "LONG"
POINT_ID_COLUMN = "ID"


def append_utf8(path: str | os.PathLike, text) -> Path:
    """Append one or more UTF-8 lines, matching the R helper."""
    lines = [text] if isinstance(text, str) else list(text)
    with open(path, "a", encoding="utf-8", newline="\n") as handle:
        for line in lines:
            handle.write(str(line).rstrip("\r\n") + "\n")
    return Path(path)


def safe_write_lines(text, path: str | os.PathLike,
                     max_attempts: int = 5, delay_sec: float = 1) -> Path:
    """Write UTF-8 lines with bounded retries, matching the R helper."""
    import time
    lines = [text] if isinstance(text, str) else list(text)
    for attempt in range(1, int(max_attempts) + 1):
        try:
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                for line in lines:
                    handle.write(str(line).rstrip("\r\n") + "\n")
            return Path(path)
        except OSError as exc:
            if attempt >= int(max_attempts):
                raise OSError(
                    f"Failed to write to {path} after {max_attempts} attempts: {exc}"
                ) from exc
            time.sleep(float(delay_sec))
    raise AssertionError("unreachable")


def write_sequence_phase_file(source_file: str | os.PathLike,
                              target_file: str | os.PathLike,
                              treatment: int, phase: int) -> Path:
    """Write an SQX containing only one selected treatment/phase row."""
    lines = Path(source_file).read_text(encoding="utf-8").splitlines()
    output: list[str] = []
    in_treatments = False
    matched = False
    row_pattern = re.compile(r"^\s*(\d+)\s+(\d+)\s+\d+\s+\d+\s+(.*)$")
    for line in lines:
        if line.startswith("*TREATMENTS"):
            in_treatments = True
            output.append(line)
            continue
        if in_treatments and line.startswith("*"):
            in_treatments = False
            if not output or output[-1]:
                output.append("")
            output.append(line)
            continue
        if in_treatments and (match := row_pattern.match(line)):
            if int(match.group(1)) == int(treatment) and int(match.group(2)) == int(phase):
                output.append(" 1 1 1 0 " + match.group(3))
                matched = True
            continue
        output.append(line)
    if not matched:
        raise ValueError(
            f"No sequence treatment row found for treatment={treatment}, phase={phase}"
        )
    return safe_write_lines(output, target_file)

def _is_leap(year: int) -> bool:
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)

def create_grid_points(boundary_shape: gpd.GeoDataFrame,
                       spacing_m: int,
                       output_path: str) -> gpd.GeoDataFrame:
    ALBERS_CRS = "EPSG:5070"   # USA Contiguous Albers Equal Area (metres)

    projected = boundary_shape.to_crs(ALBERS_CRS)
    minx, miny, maxx, maxy = projected.total_bounds

    xs = np.arange(math.floor(minx), math.ceil(maxx) + spacing_m, spacing_m)
    ys = np.arange(math.floor(miny), math.ceil(maxy) + spacing_m, spacing_m)
    grid_pts = gpd.GeoDataFrame(
        geometry=[Point(x, y) for y in ys for x in xs],
        crs=ALBERS_CRS,
    )

    inside = gpd.sjoin(grid_pts, projected[["geometry"]], how="inner",
                       predicate="within").drop_duplicates("geometry")

    if inside.empty:
        raise RuntimeError("STEP 0 FAILED: No grid points created inside boundary.")

    inside = inside.to_crs("EPSG:4326").reset_index(drop=True)
    inside[LAT_COLUMN]      = inside.geometry.y.round(6)
    inside[LONG_COLUMN]     = inside.geometry.x.round(6)
    inside[POINT_ID_COLUMN] = [f"{i+1:08d}" for i in range(len(inside))]

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    inside.to_file(output_path)
    return inside

def load_existing_points(input_path: str, output_path: str) -> gpd.GeoDataFrame:
    if not os.path.exists(input_path):
        raise FileNotFoundError(f"Existing point shapefile not found: {input_path}")

    pts = gpd.read_file(input_path)

    if not all(pts.geometry.geom_type.isin(["Point", "MultiPoint"])):
        print(f"Geometry is [{pts.geometry.geom_type.unique()}]; converting to centroids.")
        pts = pts.copy()
        pts["geometry"] = pts.geometry.centroid

    pts = pts.to_crs("EPSG:4326").reset_index(drop=True)
    pts[LAT_COLUMN]  = pts.geometry.y.round(6)
    pts[LONG_COLUMN] = pts.geometry.x.round(6)

    if POINT_ID_COLUMN not in pts.columns:
        pts[POINT_ID_COLUMN] = [f"{i+1:08d}" for i in range(len(pts))]
    else:
        ids = pts[POINT_ID_COLUMN].astype(str)
        bad = ids.isna() | (ids == "") | ids.duplicated()
        if bad.any():
            print("ID column has NA/blank/duplicates; regenerating sequential IDs.")
            pts[POINT_ID_COLUMN] = [f"{i+1:08d}" for i in range(len(pts))]
        else:
            unique_order = dict(zip(ids.unique(), range(len(ids.unique()))))
            pts[POINT_ID_COLUMN] = ids.map(lambda x: f"{unique_order[x]+1:08d}")

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    pts.to_file(output_path)
    return pts

def _read_wth_file(path: str):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()

    data_start = next(
        (i for i, ln in enumerate(lines) if re.match(r"^\s*\d", ln)),
        None
    )

    if data_start is None:
        return lines, None

    header_lines = [ln.rstrip() for ln in lines[:data_start]]
    data_lines   = [ln.rstrip() for ln in lines[data_start:]]

    clean  = [re.sub(r"\bNA\b|\bNaN\b", " -99.0 ", ln) for ln in data_lines]
    rows   = [ln.split() for ln in clean if ln.strip()]

    if not rows:
        return header_lines, None

    ncols  = max(len(r) for r in rows)
    padded = [r + ["-99.0"] * (ncols - len(r)) for r in rows]
    arr    = np.array(padded, dtype=float)
    df     = pd.DataFrame(arr)
    return header_lines, df

def _get_year_doy(date_code: float, year_format: str):
    dc  = int(date_code)
    if year_format == "YYDDD":
        yy   = dc // 1000
        doy  = dc % 1000
        year = (2000 + yy) if yy < 80 else (1900 + yy)
    else:
        year = dc // 1000
        doy  = dc % 1000
    return year, doy

def _make_date_code(year: int, doy: int, year_format: str) -> int:
    if year_format == "YYDDD":
        return (year % 100) * 1000 + doy
    return year * 1000 + doy

def _format_wth_row(date_code: int, vals: np.ndarray, year_format: str) -> str:
    fmt_date  = f"{date_code:07d}" if year_format == "YYYYDDD" else f"{date_code:05d}"
    num_parts = "".join(f"{v:6.1f}" for v in vals)
    return f"{fmt_date:>7s}{num_parts}".replace(" -99.0", "  -99")

def extend_weather_repeat_single_ignore_partial(
    path: str,
    ref_start_year: int,
    ref_end_year: int,
    target_end_year: int,
    verbose: bool = True,
) -> bool:
    header_lines, df = _read_wth_file(path)
    if df is None or df.empty:
        return False

    sample      = int(df.iloc[0, 0])
    year_format = "YYDDD" if len(str(sample)) <= 5 else "YYYYDDD"

    df["_year"] = df.iloc[:, 0].apply(lambda x: _get_year_doy(x, year_format)[0])
    df["_doy"]  = df.iloc[:, 0].apply(lambda x: _get_year_doy(x, year_format)[1])

    year_counts    = df.groupby("_year").size()
    complete_years = [
        yr for yr, cnt in year_counts.items()
        if cnt == (366 if _is_leap(yr) else 365)
    ]

    if not complete_years:
        import warnings
        warnings.warn(f"No complete years in {path}; using first 365 rows as fallback.")
        chosen_ref = ref_end_year
        n_take     = min(365, len(df))
        df_trunc   = df.iloc[:n_take].copy()
        last_full  = int(df_trunc["_year"].iloc[-1])
    else:
        prior      = [y for y in complete_years if y <= ref_end_year]
        chosen_ref = max(prior) if prior else max(complete_years)
        last_full  = max(complete_years)
        df_trunc   = df[df["_year"] <= last_full].copy()

    if last_full >= target_end_year:
        return True   # already covers target

    body_cols = [c for c in df_trunc.columns if c not in ("_year", "_doy")]

    ref_block = df[df["_year"] == chosen_ref][body_cols].copy().reset_index(drop=True)
    if ref_block.empty:
        ref_block = df_trunc[body_cols].iloc[:365].copy().reset_index(drop=True)

    ref_doys        = ref_block.iloc[:, 0].apply(lambda x: _get_year_doy(x, year_format)[1])
    ref_yr_in_block = _get_year_doy(ref_block.iloc[0, 0], year_format)[0]
    ref_dates       = pd.to_datetime(ref_yr_in_block * 1000 + ref_doys.values, format="%Y%j")
    ref_mmdd        = ref_dates.strftime("%m-%d")

    base_df = df_trunc[body_cols].copy().reset_index(drop=True)

    added = []
    for tgt_year in range(last_full + 1, target_end_year + 1):
        n_days    = 366 if _is_leap(tgt_year) else 365
        tgt_dates = pd.date_range(f"{tgt_year}-01-01", periods=n_days, freq="D")
        tgt_mmdd  = tgt_dates.strftime("%m-%d")

        idx_rows = []
        for mm in tgt_mmdd:
            cands = np.where(ref_mmdd == mm)[0]
            if len(cands):
                idx_rows.append(int(cands[0]))
            elif mm == "02-29":
                c228 = np.where(ref_mmdd == "02-28")[0]
                idx_rows.append(int(c228[0]) if len(c228) else 0)
            else:
                fallback = 0
                for k in range(1, 6):
                    prev = (tgt_dates[tgt_mmdd.tolist().index(mm)] -
                            pd.Timedelta(days=k)).strftime("%m-%d")
                    pc   = np.where(ref_mmdd == prev)[0]
                    if len(pc):
                        fallback = int(pc[0])
                        break
                idx_rows.append(fallback)

        blk            = ref_block.iloc[idx_rows].copy().reset_index(drop=True)
        new_codes      = [_make_date_code(tgt_year, doy + 1, year_format) for doy in range(n_days)]
        blk.iloc[:, 0] = new_codes
        blk            = blk.fillna(-99.0)
        added.append(blk)

    final_df = pd.concat([base_df] + added, ignore_index=True) if added else base_df

    date_codes = final_df.iloc[:, 0].astype(int)
    val_cols   = final_df.iloc[:, 1:]
    date_strs  = date_codes.apply(
        lambda dc: (f"{dc:07d}" if year_format == "YYYYDDD" else f"{dc:05d}")
    )
    val_strs = val_cols.apply(
        lambda col: col.fillna(-99.0).map(lambda v: f"{v:6.1f}"), axis=0
    )
    rows_out = date_strs.str.rjust(7) + val_strs.apply(lambda r: "".join(r.values), axis=1)
    rows_out = rows_out.str.replace(" -99.0", "  -99")

    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(header_lines) + "\n")
        fh.write("\n".join(rows_out.tolist()) + "\n")

    if verbose:
        print(f"Wrote extended file: {path} up to {target_end_year}")
    return True

def write_dssbatch(experiment_file: str, trtno_list: list,
                   batch_path: str, run_mode: str = "experiment") -> None:
    mode_tag = "EXPERIMENT" if run_mode == "experiment" else "SEQUENCE"
    header   = (
        f"$BATCH({mode_tag})\n"
        "!\n"
        "@ FILEX                                                                                        "
        "TRTNO RP SQ OP CO\n"
    )
    fname = os.path.basename(experiment_file)
    lines = []
    for trt in trtno_list:
        # FileX must start at column 1 (no leading space): CSM.for computes
        # END_POS=INDEX(line, BLANK) then reads FILEX=line(END_POS-12:END_POS-1).
        # A leading space puts the first blank at column 1 -> negative substring
        # index -> "Substring out of bounds" crash in CSM.for.
        filex_padded = f"{fname:<93s}"
        lines.append(f"{filex_padded}{trt:6d}  1  0  1  0")

    with open(batch_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(header)
        fh.write("\n".join(lines) + "\n")

def write_dssbatch_sequence(experiment_file: str, trt: int,
                            seq_start: int, seq_end: int,
                            batch_path: str) -> None:
    fname  = os.path.basename(experiment_file)
    header = (
        "$BATCH(SEQUENCE)\n"
        "!\n"
        "@ FILEX                                                                                        "
        "TRTNO RP SQ OP CO\n"
    )
    lines = []
    for sq in range(seq_start, seq_end + 1):
        # Column layout is load-bearing in SEQUENCE mode. CSM.for reads the
        # treatment fields from CHARTEST(93:113) with FORMAT(3(1X,I6)):
        #   cols 94-99 = TRTNO, 101-106 = RP, 108-113 = ROTNO/SQ.
        # The SQ (rotation) field MUST land in 108-113; if it does not, sequence
        # mode mis-reads the rotation number and aborts with libgfortran IOSTAT
        # 5010 (read overflow) while parsing the FileX. FileX still starts in
        # column 1 (a leading blank breaks CSM's INDEX/substring math, see
        # write_dssbatch). Build it field-by-field so the columns are exact:
        #   <92 FileX> SP <TRTNO i6> SP <RP i6> SP <SQ i6> SP <OP i6> SP <CO i6>
        lines.append(f"{fname:<92s} {trt:6d} {1:6d} {sq:6d} {1:6d} {0:6d}")

    with open(batch_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(header)
        fh.write("\n".join(lines) + "\n")

def normalize_treatment_list(treatment_start: int,
                             treatment_end: int,
                             treatment_list: Optional[list] = None,
                             treatments: Optional[list] = None) -> list[int]:
    has_list = treatment_list is not None and len(treatment_list) > 0
    has_legacy = treatments is not None and len(treatments) > 0
    if has_list and has_legacy:
        raise ValueError(
            "Use only one explicit treatment selector: 'treatment_list'. "
            "The legacy 'treatments' argument is ambiguous and is ignored by new configs."
        )
    explicit = treatment_list
    if has_legacy:
        explicit = treatments
        has_list = True

    if has_list:
        raw_values = explicit
    else:
        start = int(treatment_start)
        end = int(treatment_end)
        if end < start:
            raise ValueError(
                f"treatment_end ({end}) must be >= treatment_start ({start})."
            )
        raw_values = range(start, end + 1)

    seen = set()
    trt_vec: list[int] = []
    for value in raw_values:
        try:
            trt = int(value)
        except (TypeError, ValueError):
            continue
        if trt < 1:
            raise ValueError("Treatment IDs must be positive integers.")
        if trt not in seen:
            seen.add(trt)
            trt_vec.append(trt)

    if not trt_vec:
        raise ValueError(
            "No valid treatments selected. Set treatment_start/treatment_end "
            "or treatment_list."
        )
    return trt_vec

def run_dssat(run_dir: str, exe: str, run_mode_flag: str = "A",
              filex: str = "", model: Optional[str] = None,
              timeout: Optional[float] = None) -> None:
    if run_mode_flag in ("B", "Q", "N", "S"):
        arg = "DSSBatch.V48"
    else:
        arg = filex if filex else "DSSBatch.V48"
    exe_path = shutil.which(exe) if not os.path.isabs(exe) else exe
    exe_path = exe_path or exe
    if os.path.isabs(exe_path) and not os.path.exists(exe_path):
        raise FileNotFoundError(f"DSSAT executable not found: {exe_path}")

    cmd = [exe_path, run_mode_flag, arg]
    if model:
        cmd = [exe_path, str(model), run_mode_flag, arg]
    result = subprocess.run(
        cmd,
        cwd=run_dir,
        timeout=timeout,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    log_path = os.path.join(run_dir, f"dssat_{run_mode_flag}_stdout_stderr.log")
    output = "\n".join(part for part in (result.stdout, result.stderr) if part)
    if output:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(output.rstrip() + "\n")
    if result.returncode != 0:
        tail = " | ".join(output.splitlines()[-12:]) if output else "<no stdout/stderr captured>"
        raise RuntimeError(
            f"DSSAT exited with status {result.returncode} in mode {run_mode_flag} "
            f"using {arg}. Log: {log_path}. Tail: {tail}"
        )


# Backward-compatible aliases for consumers that imported the private helpers
# before the v0.3.0 public API promotion.
_write_dssbatch = write_dssbatch
_write_dssbatch_sequence = write_dssbatch_sequence
_normalize_treatment_list = normalize_treatment_list
_run_dssat = run_dssat

def _read_csv_safe(path: str) -> Optional[pd.DataFrame]:
    if not os.path.exists(path):
        return None
    try:
        df = pd.read_csv(path, index_col=False, encoding="utf-8")
        return df if not df.empty else None
    except Exception:
        return None

def _merge_supplemental(point_dir: str, master_runs: pd.DataFrame) -> pd.DataFrame:
    mr = master_runs.copy()

    # --- soilorg ---
    soilorg = _read_csv_safe(os.path.join(point_dir, "soilorg.csv"))
    if soilorg is not None and "RUN" in soilorg.columns and "SOMCT" in soilorg.columns:
        so = (soilorg.groupby("RUN")
                     .agg(SOMCT_start=("SOMCT", "first"),
                          SOMCT_end=("SOMCT", "last"))
                     .reset_index()
                     .rename(columns={"RUN": "RUNNO"}))
        mr = mr.merge(so, on="RUNNO", how="left")
    else:
        mr["SOMCT_start"] = None
        mr["SOMCT_end"]   = None

    # --- soilni ---
    soilni = _read_csv_safe(os.path.join(point_dir, "soilni.csv"))
    if soilni is not None and "RUN" in soilni.columns:
        agg_dict = {}
        if "NAPC" in soilni.columns:
            agg_dict["NAPC"] = ("NAPC", "last")
        if "NLCC" in soilni.columns:
            agg_dict["NLCC"] = ("NLCC", "last")
        if "NI#M" in soilni.columns:
            agg_dict["NIM"]  = ("NI#M", "last")
        if agg_dict:
            sn = (soilni.groupby("RUN")
                        .agg(**agg_dict)
                        .reset_index()
                        .rename(columns={"RUN": "RUNNO"}))
            mr = mr.merge(sn, on="RUNNO", how="left")
    if "NAPC" not in mr.columns: mr["NAPC"] = None
    if "NLCC" not in mr.columns: mr["NLCC"] = None
    if "NIM"  not in mr.columns: mr["NIM"]  = None

    # --- soilwat ---
    soilwat = _read_csv_safe(os.path.join(point_dir, "soilwat.csv"))
    if soilwat is not None and "RUN" in soilwat.columns:
        agg_dict = {}
        if "IR#C" in soilwat.columns:
            agg_dict["IRC"]  = ("IR#C", "last")
        if "IRRC" in soilwat.columns:
            agg_dict["IRRC"] = ("IRRC", "last")
        if agg_dict:
            sw = (soilwat.groupby("RUN")
                         .agg(**agg_dict)
                         .reset_index()
                         .rename(columns={"RUN": "RUNNO"}))
            mr = mr.merge(sw, on="RUNNO", how="left")
    if "IRC"  not in mr.columns: mr["IRC"]  = None
    if "IRRC" not in mr.columns: mr["IRRC"] = None

    return mr

def _build_result_rows(ID: str, summary: pd.DataFrame,
                       mr: pd.DataFrame,
                       is_sequence: bool = False) -> pd.DataFrame:
    """Assemble the result DataFrame from a summary table and the augmented
    master_runs table (mr). Shared by experiment and sequence mode.

    DSSAT's ``TRNO`` column is the authoritative treatment identifier in both
    experiment and sequence output. ``RUNNO`` is only a fallback for malformed
    output without ``TRNO``; inferring from a constant TRNO is unsafe because a
    correctly selected single treatment is necessarily constant.
    """
    mr_idx = mr.set_index("RUNNO") if "RUNNO" in mr.columns else mr

    def _reindex_col(col_name: str) -> np.ndarray:
        if col_name in mr_idx.columns:
            return mr_idx[col_name].reindex(summary["RUNNO"]).values
        return np.full(len(summary), None)

    def _reindex_numeric(col_name: str) -> np.ndarray:
        if col_name not in mr_idx.columns:
            return np.full(len(summary), np.nan)
        return (pd.to_numeric(mr_idx[col_name].reindex(summary["RUNNO"]),
                              errors="coerce")
                  .to_numpy(dtype=float, na_value=np.nan))

    somct_start = _reindex_numeric("SOMCT_start")
    somct_end   = _reindex_numeric("SOMCT_end")
    somct_delta = somct_end - somct_start

    _trno = summary.get("TRNO")
    treatment_col = _trno if _trno is not None else summary["RUNNO"]

    return pd.DataFrame({
        "point_id":                               ID,
        "run_number":                             summary["RUNNO"],
        "treatment":                              treatment_col,
        "crop_code":                              summary.get("CR"),
        "latitude":                               summary.get("LAT"),
        "longitude":                              summary.get("LONG"),
        "weather_station_id":                     summary.get("WSTA"),
        "soil_profile_id":                        summary.get("SOIL_ID"),
        "dssat_file_id":                          summary.get("EXNAME"),
        "dssat_description":                      summary.get("TNAM"),
        "planting_date":                          summary.get("PDAT"),
        "emergence_date":                         summary.get("EDAT"),
        "harvest_date":                           summary.get("HDAT"),
        "year_planting":                          pd.to_numeric(summary.get("PYEAR"), errors="coerce"),
        "year_harvest":                           summary.get("HYEAR"),
        "top_weight_kg_ha":                       summary.get("CWAM"),
        "final_grain_kg_ha":                      summary.get("HWAM"),
        "removed_residue_kg_ha":                  summary.get("BWAH"),
        "soil_organic_carbon_start_kg_C_ha":      somct_start,
        "soil_organic_carbon_end_kg_C_ha":        somct_end,
        "soil_organic_carbon_delta_kg_C_ha":      somct_delta,
        "final_irrigation_applications_count":    _reindex_col("IRC"),
        "final_irrigation_amount_mm":             _reindex_col("IRRC"),
        "inorganic_n_applied_count":              _reindex_col("NIM"),
        "inorganic_n_applied_kg_ha":              _reindex_col("NAPC"),
        "nitrate_leaching_kg_ha":                 _reindex_col("NLCC"),
        "cumulative_net_co2_emissions_kg_CO2_ha": summary.get("CO2EM"),
        "cumulative_n2o_emissions_kg_N_ha":       summary.get("N2OEM"),
    })

def _run_simulation(ID: str,
                    points_row: pd.Series,
                    dssat_run_dir: str,
                    crop_extension: str,
                    template_file_name: str,
                    template_file_path: str,
                    run_mode: str,
                    treatment_start: int,
                    treatment_end: int,
                    sequence_start: int,
                    sequence_end: int,
                    weather_start_year: int,
                    weather_end_year: int,
                    dssat_exe_path: str,
                    treatment_list: Optional[list] = None,
                    treatments: Optional[list] = None) -> Optional[pd.DataFrame]:
    point_dir = os.path.join(dssat_run_dir, ID)
    os.makedirs(point_dir, exist_ok=True)

    def log_run_error(message: str) -> None:
        line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] ID {ID}: {message}"
        try:
            with open(os.path.join(point_dir, "_run_error.log"), "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except Exception:
            pass
        print(line)

    ext_map   = {"MZ": "MZX", "WH": "WHX", "SB": "SBX", "SC": "SCX",
                 "BA": "BAX", "SG": "SGX", "RI": "RIX"}
    ext       = ext_map.get(crop_extension, template_file_name.rsplit(".", 1)[-1])
    exp_fname = f"{template_file_name.rsplit('.', 1)[0]}.{ext}"
    exp_path  = os.path.join(point_dir, exp_fname)

    # Copy template into the point directory when the experiment file is absent
    # (mirrors R engine's file.copy(template_file_path, ".") fallback).
    if not os.path.isfile(exp_path):
        if os.path.isfile(template_file_path):
            import shutil
            shutil.copy2(template_file_path, exp_path)
        else:
            log_run_error(f"Template file not found: {template_file_path}")
            return None

    results_template = {
        "point_id": [], "run_number": [], "treatment": [], "crop_code": [],
        "latitude": [], "longitude": [], "weather_station_id": [],
        "soil_profile_id": [], "dssat_file_id": [], "dssat_description": [],
        "planting_date": [], "emergence_date": [], "harvest_date": [],
        "year_planting": [], "year_harvest": [],
        "top_weight_kg_ha": [], "final_grain_kg_ha": [], "removed_residue_kg_ha": [],
        "soil_organic_carbon_start_kg_C_ha": [], "soil_organic_carbon_end_kg_C_ha": [],
        "soil_organic_carbon_delta_kg_C_ha": [],
        "final_irrigation_applications_count": [], "final_irrigation_amount_mm": [],
        "inorganic_n_applied_count": [], "inorganic_n_applied_kg_ha": [],
        "nitrate_leaching_kg_ha": [],
        "cumulative_net_co2_emissions_kg_CO2_ha": [],
        "cumulative_n2o_emissions_kg_N_ha": [],
    }
    results = pd.DataFrame(results_template)

    try:
        trt_vec = normalize_treatment_list(
            treatment_start, treatment_end, treatment_list, treatments
        )

        # ------------------------------------------------------------------ #
        # EXPERIMENT MODE                                                      #
        # ------------------------------------------------------------------ #
        if run_mode == "experiment":
            batch_path = os.path.join(point_dir, "DSSBatch.V48")
            write_dssbatch(exp_path, trt_vec, batch_path, run_mode="experiment")
            # Mode B is the batch runner and therefore honours the explicit
            # treatment rows written above. Mode A runs the FileX directly and
            # silently executes every treatment, defeating treatment_start /
            # treatment_end / treatment_list selection.
            run_dssat(point_dir, dssat_exe_path, "B")

            summary = _read_csv_safe(os.path.join(point_dir, "summary.csv"))
            if summary is None or summary.empty:
                raise RuntimeError(
                    "DSSAT produced no 'summary.csv'. The experiment file's "
                    "OUTPUTS line must end in FMOPT = 'C' (CSV output); 'A' "
                    "writes Summary.OUT instead. Also check ERROR.OUT / "
                    "WARNING.OUT in this folder."
                )

            summary["PYEAR"] = summary["PDAT"].astype(str).str[:4]

            master_runs = summary[["RUNNO"]].copy()
            master_runs = _merge_supplemental(point_dir, master_runs)
            run_results = _build_result_rows(ID, summary, master_runs)
            results     = pd.concat([results, run_results], ignore_index=True)

        # ------------------------------------------------------------------ #
        # SEQUENCE MODE                                                        #
        # ------------------------------------------------------------------ #
        elif run_mode == "sequence":
            all_seq_results = []

            for trt in trt_vec:
                batch_path = os.path.join(point_dir, "DSSBatch.V48")
                write_dssbatch_sequence(exp_path, trt,
                                        sequence_start, sequence_end,
                                        batch_path)
                run_dssat(point_dir, dssat_exe_path, "Q")

                summary = _read_csv_safe(os.path.join(point_dir, "summary.csv"))
                if summary is None or summary.empty:
                    log_run_error(
                        f"trt {trt}: DSSAT produced no 'summary.csv' "
                        "(FMOPT must be 'C'; see ERROR.OUT / WARNING.OUT)."
                    )
                    continue

                summary["PYEAR"] = summary["PDAT"].astype(str).str[:4]
                if "TRNO" not in summary.columns or summary["TRNO"].isna().all():
                    summary["TRNO"] = trt

                master_runs = summary[["RUNNO"]].copy()
                master_runs = _merge_supplemental(point_dir, master_runs)
                trt_results = _build_result_rows(ID, summary, master_runs,
                                                 is_sequence=True)
                all_seq_results.append(trt_results)

            if all_seq_results:
                results = pd.concat([results] + all_seq_results, ignore_index=True)

        # DSSAT coordinate overwrite fallback
        if not results.empty:
            try:
                results["latitude"]  = float(points_row.get("LAT",  np.nan))
                results["longitude"] = float(points_row.get("LONG", np.nan))
            except Exception:
                pass
            out_csv = os.path.join(point_dir, f"results_{ID}.csv")
            results.to_csv(out_csv, index=False, na_rep="", encoding="utf-8")
        return results

    except Exception as exc:
        log_run_error(f"FATAL: {exc}")
        return None

def _run_one_point(args: dict) -> Optional[pd.DataFrame]:
    ID = args["ID"]
    row_dict = args["row_dict"]
    dssat_run_dir = args["dssat_run_dir"]
    row = pd.Series(row_dict)
    return _run_simulation(
        ID, row, dssat_run_dir,
        args["crop_extension"], args["template_file_name"], args["template_file_path"],
        args["run_mode"], args["treatment_start"], args["treatment_end"],
        args["sequence_start"], args["sequence_end"],
        args["weather_start_year"], args["weather_end_year"],
        args["dssat_exe_path"], args.get("treatment_list"), args.get("treatments")
    )


run_simulation = _run_simulation
