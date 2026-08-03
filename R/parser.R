#' DSSAT output-file parsers (R mirror of python/dssatengine/output_parser.py)
#'
#' Parses the two families of DSSAT-CSM result files:
#'   * Daily time-series (PlantGro.OUT, PlantN.OUT, MgmtOps.OUT, GHG.OUT, ...):
#'     `*RUN` blocks, each with a `@YEAR DOY ...` header then numeric rows.
#'   * Summary / scalar files (Summary.OUT fixed-width; Evaluate.OUT sim-vs-meas).
#' Plus the FMOPT='C' CSV twins (summary.csv, plantgro.csv).
#'
#' Base R only (no sf/DSSAT deps) so it is light and matches the Python contract:
#' identical function names, the -99 sentinel -> NA, and a `date` column derived
#' from YEAR+DOY. Sequence (.SQX) runs with per-block headers (different crops)
#' are concatenated by column name; each row carries run / treatment /
#' crop_model / rotation identifiers.
#'
#' @name parser
NULL

.DSSAT_MISSING <- -99.0

# Non-data files (free-text reports, narrative per-timestep balances, run lists).
# The per-season balance *summaries* (SWBalSum/SoilCBalSum/SoilNBalSum) ARE tabular
# (one row per run) and are intentionally NOT listed; only the narrative `*Bal`
# files are.
.NON_TABULAR <- c(
  "info.out", "version.out", "runlist.out", "warning.out", "error.out",
  "soilnibal.out", "soilnobal.out", "soilwatbal.out", "soilcbal.out",
  "overview.out", "measured.out"
)

#' Convert a DSSAT YYDDD / YYYYDDD date code to a Date (NA if missing/invalid)
#' @export
yyddd_to_date <- function(code) {
  one <- function(x) {
    if (is.na(x)) return(as.Date(NA))
    s <- suppressWarnings(as.integer(round(as.numeric(x))))
    if (is.na(s) || s %in% c(-99L, 0L)) return(as.Date(NA))
    s <- as.character(abs(s))
    if (nchar(s) <= 5) {                       # YYDDD
      s <- formatC(s, width = 5, flag = "0")
      yy <- as.integer(substr(s, 1, 2)); doy <- as.integer(substr(s, 3, 5))
      year <- if (yy < 80) 2000L + yy else 1900L + yy
    } else {                                   # YYYYDDD
      s <- formatC(s, width = 7, flag = "0")
      year <- as.integer(substr(s, 1, 4)); doy <- as.integer(substr(s, 5, 7))
    }
    max_doy <- if ((year %% 4L == 0L && year %% 100L != 0L) || year %% 400L == 0L) 366L else 365L
    if (is.na(doy) || doy < 1 || doy > max_doy) return(as.Date(NA))
    as.Date(paste0(year, "-01-01")) + (doy - 1)
  }
  out <- as.Date(vapply(code, function(x) as.numeric(one(x)), numeric(1)),
                 origin = "1970-01-01")
  out
}

# Coerce character columns to numeric where sensible, mapping -99 -> NA.
.to_numeric <- function(df, columns = NULL) {
  cols <- if (is.null(columns)) names(df) else columns
  for (c in cols) {
    coerced <- suppressWarnings(as.numeric(df[[c]]))
    if (any(!is.na(coerced)) || all(is.na(df[[c]]))) {
      coerced[!is.na(coerced) & abs(coerced - .DSSAT_MISSING) < 1e-6] <- NA
      df[[c]] <- coerced
    }
  }
  df
}

.add_date_from_year_doy <- function(df) {
  if (all(c("YEAR", "DOY") %in% names(df))) {
    yr <- suppressWarnings(as.integer(df$YEAR))
    doy <- suppressWarnings(as.integer(df$DOY))
    d <- rep(as.Date(NA), nrow(df))
    leap <- (yr %% 4L == 0L & yr %% 100L != 0L) | yr %% 400L == 0L
    ok <- !is.na(yr) & !is.na(doy) & doy >= 1 & doy <= ifelse(leap, 366L, 365L)
    d[ok] <- as.Date(paste0(yr[ok], "-01-01")) + (doy[ok] - 1)
    df$date <- d
  }
  df
}

# Bind a list of data.frames by column name, filling missing columns with NA
# (mirrors pandas concat-by-name; needed for sequence rotations with different
# crop headers).
.rbind_fill <- function(frames) {
  frames <- Filter(function(x) !is.null(x) && nrow(x) > 0, frames)
  if (length(frames) == 0) return(NULL)
  all_cols <- unique(unlist(lapply(frames, names)))
  norm <- lapply(frames, function(df) {
    miss <- setdiff(all_cols, names(df))
    for (m in miss) df[[m]] <- NA
    df[all_cols]
  })
  do.call(rbind, norm)
}

# --------------------------------------------------------------------------- #
#  Daily time-series                                                          #
# --------------------------------------------------------------------------- #
#' Parse any DSSAT daily time-series .OUT file into a tidy data.frame
#' @export
parse_timeseries <- function(path, add_date = TRUE) {
  if (!file.exists(path)) return(data.frame())
  lines <- readLines(path, warn = FALSE)

  frames <- list()
  rotation <- 0L
  run_no <- NA_integer_
  meta <- list(treatment = NA_integer_, crop_model = NA_character_)
  header <- NULL
  rows <- list()
  seen_block <- FALSE

  flush <- function() {
    if (!is.null(header) && length(rows) > 0) {
      mat <- do.call(rbind, rows)
      df <- as.data.frame(mat, stringsAsFactors = FALSE)
      names(df) <- header
      df <- .to_numeric(df)
      df$run <- run_no
      df$treatment <- if (!is.na(meta$treatment)) meta$treatment else run_no
      df$crop_model <- meta$crop_model
      rotation <<- rotation + 1L
      df$rotation <- rotation
      frames[[length(frames) + 1L]] <<- df
    }
    header <<- NULL
    rows <<- list()
  }

  for (ln in lines) {
    if (startsWith(ln, "*RUN")) {
      flush()
      seen_block <- TRUE
      m <- regmatches(ln, regexec("\\*RUN\\s+(\\d+)", ln))[[1]]
      run_no <- if (length(m) == 2) as.integer(m[2]) else NA_integer_
      meta <- list(treatment = NA_integer_, crop_model = NA_character_)
      tail <- sub("^[^:]*:", "", ln)
      toks <- strsplit(trimws(tail), "\\s+")[[1]]
      cm <- toks[grepl("^[A-Z]{2}[A-Z0-9]{3}[0-9]{3}$", toks)]
      if (length(cm) >= 1) meta$crop_model <- cm[1]
    } else if (grepl("^\\s*MODEL", ln) && grepl(":", ln) && is.na(meta$crop_model)) {
      m <- regmatches(ln, regexec("MODEL\\s*:\\s*(\\S+)", ln))[[1]]
      if (length(m) == 2) meta$crop_model <- m[2]
    } else if (grepl("^\\s*TREATMENT", ln)) {
      m <- regmatches(ln, regexec("TREATMENT\\s+(\\d+)", ln))[[1]]
      if (length(m) == 2) meta$treatment <- as.integer(m[2])
    } else if (startsWith(ln, "@")) {
      # Any '@' line is the block's column header. Most files key on YEAR/DOY/DAS
      # (daily series) but some key differently — Leaves.OUT by leaf number
      # (@ LNUM ...), the balance summaries by run (@Run FILEX TN CR ...).
      header <- strsplit(trimws(sub("^@", "", ln)), "\\s+")[[1]]
      rows <- list()
    } else if (!is.null(header) && grepl("^\\s*-?\\d", ln) && !startsWith(ln, "*")) {
      parts <- strsplit(trimws(ln), "\\s+")[[1]]
      if (length(parts) >= length(header)) {
        rows[[length(rows) + 1L]] <- parts[seq_along(header)]
      } else if (length(parts) > 0) {
        rows[[length(rows) + 1L]] <- c(parts, rep("-99", length(header) - length(parts)))
      }
    }
  }
  if (!seen_block) run_no <- 1L
  flush()

  out <- .rbind_fill(frames)
  if (is.null(out)) return(data.frame())
  if (add_date) out <- .add_date_from_year_doy(out)
  rownames(out) <- NULL
  out
}

#' @rdname parse_timeseries
#' @export
parse_plantgro <- function(path) parse_timeseries(path)

#' @rdname parse_timeseries
#' @export
parse_plantn <- function(path) parse_timeseries(path)

# --------------------------------------------------------------------------- #
#  Summary.OUT (fixed-width)                                                   #
# --------------------------------------------------------------------------- #
.summary_spans <- function(header_line) {
  h <- if (startsWith(header_line, "@")) paste0(" ", substring(header_line, 2)) else header_line
  m <- gregexpr("\\S+", h)[[1]]
  starts <- as.integer(m)
  lens <- attr(m, "match.length")
  ends <- starts + lens - 1L
  names_ <- vapply(seq_along(starts), function(i)
    sub("\\.+$", "", substr(h, starts[i], ends[i])), character(1))
  prev <- 0L
  spans <- vector("list", length(starts))
  for (i in seq_along(starts)) {
    spans[[i]] <- list(name = names_[i], start = prev + 1L, end = ends[i])
    prev <- ends[i]
  }
  spans
}

#' Parse Summary.OUT into one row per run (all columns; spacey text preserved)
#' @export
parse_summary <- function(path) {
  if (!file.exists(path)) return(data.frame())
  lines <- readLines(path, warn = FALSE)
  hdr_idx <- which(grepl("^\\s*@", lines) & grepl("RUNNO", lines))
  if (length(hdr_idx) == 0) return(data.frame())
  hdr_idx <- hdr_idx[1]
  spans <- .summary_spans(lines[hdr_idx])
  n <- length(spans)

  recs <- list()
  for (ln in lines[(hdr_idx + 1):length(lines)]) {
    if (!grepl("^\\s*\\d", ln)) next
    rec <- vapply(seq_len(n), function(i) {
      s <- spans[[i]]$start
      e <- if (i == n) nchar(ln) else spans[[i]]$end
      trimws(substr(ln, s, e))
    }, character(1))
    recs[[length(recs) + 1L]] <- rec
  }
  if (length(recs) == 0) return(data.frame())

  col_names <- vapply(spans, function(s) s$name, character(1))
  df <- as.data.frame(do.call(rbind, recs), stringsAsFactors = FALSE)
  names(df) <- col_names

  text_cols <- c("CR", "MODEL", "EXNAME", "TNAM", "FNAM", "WSTA", "SOIL_ID")
  num_cols <- setdiff(names(df), text_cols)
  df <- .to_numeric(df, columns = num_cols)
  for (c in intersect(text_cols, names(df))) df[[c]] <- trimws(df[[c]])
  for (c in names(df)[grepl("DAT$", names(df))]) {
    df[[paste0(c, "_date")]] <- yyddd_to_date(df[[c]])
  }
  rownames(df) <- NULL
  df
}

# --------------------------------------------------------------------------- #
#  Evaluate.OUT                                                                #
# --------------------------------------------------------------------------- #
#' Parse Evaluate.OUT into a long (treatment, run, variable, sim, meas) frame
#' @export
parse_evaluate <- function(path) {
  empty <- data.frame(treatment = integer(), run = integer(),
                      variable = character(), sim = numeric(), meas = numeric(),
                      stringsAsFactors = FALSE)
  if (!file.exists(path)) return(empty)
  lines <- readLines(path, warn = FALSE)
  hdr_idx <- which(startsWith(lines, "@RUN"))
  if (length(hdr_idx) == 0) return(empty)
  hdr_idx <- hdr_idx[1]
  header <- strsplit(trimws(sub("^@", "", lines[hdr_idx])), "\\s+")[[1]]
  data_lines <- lines[(hdr_idx + 1):length(lines)]
  data_lines <- data_lines[grepl("^\\s*\\d", data_lines)]
  if (length(data_lines) == 0) return(empty)
  mat <- lapply(data_lines, function(l) strsplit(trimws(l), "\\s+")[[1]])
  ncol <- length(mat[[1]])
  wide <- as.data.frame(do.call(rbind, lapply(mat, function(r) r[seq_len(ncol)])),
                        stringsAsFactors = FALSE)
  names(wide) <- header[seq_len(ncol)]

  id_cols <- c("RUN", "EXCODE", "TRNO", "TN", "RN", "CR")
  sim_cols <- Filter(function(c) {
    endsWith(c, "S") && (paste0(substr(c, 1, nchar(c) - 1), "M") %in% names(wide)) &&
      !(c %in% id_cols)
  }, names(wide))

  # DSSAT names the treatment column TRNO (older builds: TN).
  trt_col <- if ("TRNO" %in% names(wide)) "TRNO" else if ("TN" %in% names(wide)) "TN" else NA
  getcol <- function(col, i) if (!is.na(col) && col %in% names(wide))
    suppressWarnings(as.numeric(wide[[col]][i])) else NA_real_

  recs <- list()
  for (i in seq_len(nrow(wide))) {
    trt <- getcol(trt_col, i)
    run <- getcol("RUN", i)
    for (sc in sim_cols) {
      base <- substr(sc, 1, nchar(sc) - 1)
      sim <- suppressWarnings(as.numeric(wide[[sc]][i]))
      meas <- suppressWarnings(as.numeric(wide[[paste0(base, "M")]][i]))
      recs[[length(recs) + 1L]] <- data.frame(
        treatment = as.integer(trt), run = as.integer(run), variable = base,
        sim = sim, meas = meas, stringsAsFactors = FALSE)
    }
  }
  if (length(recs) == 0) return(empty)
  out <- do.call(rbind, recs)
  out$sim[!is.na(out$sim) & abs(out$sim - .DSSAT_MISSING) < 1e-6] <- NA
  out$meas[!is.na(out$meas) & abs(out$meas - .DSSAT_MISSING) < 1e-6] <- NA
  rownames(out) <- NULL
  out
}

# --------------------------------------------------------------------------- #
#  CSV twins                                                                   #
# --------------------------------------------------------------------------- #
#' Parse a DSSAT FMOPT='C' CSV twin (summary.csv, plantgro.csv)
#' @export
parse_csv <- function(path, add_date = TRUE) {
  if (!file.exists(path)) return(data.frame())
  # DSSAT appends a trailing comma to the data rows of some CSVs (so each data
  # row carries one more field than the header). Left as-is, read.csv either
  # hijacks the first column as row names or shifts every header name by one.
  # Strip a single trailing comma from each line first so header and data widths
  # match, then parse from text.
  df <- tryCatch({
    lines <- sub(",[ \t]*$", "", readLines(path, warn = FALSE))
    utils::read.csv(text = paste(lines, collapse = "\n"),
                    check.names = FALSE, stringsAsFactors = FALSE)
  }, error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(if (is.null(df)) data.frame() else df)
  for (c in names(df)) {
    if (is.numeric(df[[c]])) {
      v <- df[[c]]; v[!is.na(v) & abs(v - .DSSAT_MISSING) < 1e-6] <- NA; df[[c]] <- v
    }
  }
  if (add_date) {
    df <- .add_date_from_year_doy(df)
    for (c in names(df)[grepl("DAT$", names(df)) & !grepl("_date$", names(df))]) {
      twin <- paste0(c, "_date")
      if (!(twin %in% names(df))) df[[twin]] <- yyddd_to_date(df[[c]])
    }
  }
  df
}

# --------------------------------------------------------------------------- #
#  Dispatcher + directory reader                                              #
# --------------------------------------------------------------------------- #
#' Parse any single DSSAT output file, dispatching on name/structure
#' @export
parse_dssat_output <- function(path, add_date = TRUE) {
  name <- tolower(basename(path))
  if (endsWith(name, ".csv")) return(parse_csv(path, add_date = add_date))
  if (name %in% .NON_TABULAR) return(data.frame())   # free-text reports / narrative balances
  if (name == "summary.out") return(parse_summary(path))
  if (name == "evaluate.out") return(parse_evaluate(path))
  parse_timeseries(path, add_date = add_date)
}

#' Parse the DSSAT output files in a run directory into a named list of frames
#'
#' With `files` unset, reads every tabular `.OUT` (skipping reports/balances)
#' plus, when `include_csv` (default), the `FMOPT='C'` `.csv` twins whose stem
#' isn't already covered by a `.OUT` — so a CSV-mode run is read as fully as a
#' text run. When both forms exist the structurally safer CSV twin wins.
#' @export
read_run_directory <- function(run_dir, files = NULL, add_date = TRUE,
                               include_csv = TRUE) {
  if (!dir.exists(run_dir)) return(list())
  if (is.null(files)) {
    all <- list.files(run_dir)
    out_files <- sort(all[grepl("\\.OUT$", all, ignore.case = TRUE) &
                            !(tolower(all) %in% .NON_TABULAR)])
    candidates <- out_files
    if (include_csv) {
      csv_files <- sort(all[grepl("\\.csv$", all, ignore.case = TRUE)])
      csv_stems <- tolower(tools::file_path_sans_ext(csv_files))
      out_files <- out_files[!(tolower(tools::file_path_sans_ext(out_files)) %in% csv_stems)]
      candidates <- c(out_files, csv_files)
    }
  } else {
    candidates <- files
  }
  out <- list()
  for (fname in candidates) {
    fpath <- file.path(run_dir, fname)
    if (!file.exists(fpath)) next
    df <- parse_dssat_output(fpath, add_date = add_date)
    if (!is.null(df) && nrow(df) > 0) {
      key <- tolower(tools::file_path_sans_ext(fname))
      out[[key]] <- df
    }
  }
  out
}
