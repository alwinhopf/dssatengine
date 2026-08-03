#' dssatengine R interface
#'
#' Canonical gridded crop modeling engine for DSSAT.
#'
#' @import sf
#' @import dplyr
#' @import tidyr
#' @import stringr
#' @import lubridate
#' @import foreach
#' @import doParallel
#' @import pbapply
#' @import DSSAT
#' @import readr
#' @name dssatengine
NULL

# Column constants
LAT_COLUMN <- "LAT"
LONG_COLUMN <- "LONG"
POINT_ID_COLUMN <- "ID"

append_utf8 <- function(path, text) {
  con <- file(path, open = "a", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  writeLines(text, con = con)
}

write_sequence_phase_file <- function(source_file, target_file, treatment, phase) {
  lines <- readLines(source_file, warn = FALSE, encoding = "UTF-8")
  out <- character()
  in_treatments <- FALSE
  matched <- FALSE

  for (line in lines) {
    if (startsWith(line, "*TREATMENTS")) {
      in_treatments <- TRUE
      out <- c(out, line)
      next
    }
    if (in_treatments && startsWith(line, "*")) {
      in_treatments <- FALSE
      if (!length(out) || nzchar(tail(out, 1))) out <- c(out, "")
      out <- c(out, line)
      next
    }
    if (in_treatments && grepl("^\\s*[0-9]+\\s+[0-9]+\\s+", line)) {
      vals <- suppressWarnings(scan(text = line, what = integer(), nmax = 2, quiet = TRUE))
      if (length(vals) >= 2 && vals[1] == treatment && vals[2] == phase) {
        tail_text <- sub("^\\s*[0-9]+\\s+[0-9]+\\s+[0-9]+\\s+[0-9]+\\s+", "", line)
        out <- c(out, paste0(" 1 1 1 0 ", tail_text))
        matched <- TRUE
      }
      next
    }
    out <- c(out, line)
  }

  if (!matched) {
    stop(sprintf("No sequence treatment row found for treatment=%d, phase=%d",
                 treatment, phase), call. = FALSE)
  }
  writeLines(out, target_file, useBytes = TRUE)
  invisible(target_file)
}

#' Create a regular grid of points inside boundary_shape
#'
#' @export
create_grid_points <- function(boundary_shape, spacing_meters, output_path) {
  if (!is.numeric(spacing_meters) || length(spacing_meters) != 1L ||
      is.na(spacing_meters) || spacing_meters <= 0) {
    stop("spacing_meters must be a positive distance in metres", call. = FALSE)
  }
  if (!nrow(boundary_shape) || is.na(sf::st_crs(boundary_shape))) {
    stop("boundary_shape must be non-empty and have a defined CRS", call. = FALSE)
  }
  ll <- sf::st_transform(boundary_shape, 4326)
  bb <- sf::st_bbox(ll)
  if ((bb$xmax - bb$xmin) <= 12 && (bb$ymax - bb$ymin) <= 20) {
    center <- sf::st_coordinates(sf::st_centroid(sf::st_union(ll)))[1, ]
    zone <- max(1L, min(60L, floor((center[1] + 180) / 6) + 1L))
    metric_epsg <- if (center[2] >= 0) 32600L + zone else 32700L + zone
  } else {
    metric_epsg <- 6933L
  }
  boundary_projected <- sf::st_transform(boundary_shape, metric_epsg)
  bbox <- sf::st_bbox(boundary_projected)
  x_coords <- seq(floor(bbox$xmin), ceiling(bbox$xmax), by = spacing_meters)
  y_coords <- seq(floor(bbox$ymin), ceiling(bbox$ymax), by = spacing_meters)
  full_grid_df <- expand.grid(X = x_coords, Y = y_coords)
  grid_points_projected <- sf::st_as_sf(full_grid_df, coords = c("X", "Y"), crs = metric_epsg)
  points_in_boundary_projected <- sf::st_filter(
    grid_points_projected, boundary_projected, .predicate = sf::st_intersects
  )
  
  if (nrow(points_in_boundary_projected) == 0) stop("STEP 0 FAILED: No grid points created.")
  
  points_with_coords <- sf::st_transform(points_in_boundary_projected, 4326) %>%
    dplyr::mutate(!!LAT_COLUMN := round(sf::st_coordinates(.)[,2], 6),
                  !!LONG_COLUMN := round(sf::st_coordinates(.)[,1], 6),
                  !!POINT_ID_COLUMN := sprintf("%08d", dplyr::row_number()))
  
  sf::st_write(points_with_coords, output_path, append = FALSE, delete_layer = TRUE, quiet = TRUE)
  return(points_with_coords)
}

#' Load an existing point shapefile and standardize it to the pipeline schema
#'
#' @export
load_existing_points <- function(input_path, output_path,
                                 id_col = "ID",
                                 lat_col = "LAT",
                                 lon_col = "LONG") {
  if (!file.exists(input_path)) stop(sprintf("Existing point shapefile not found at: %s", input_path))
  pts <- sf::st_read(input_path, quiet = TRUE)
  if (is.na(sf::st_crs(pts))) stop("Input spatial data must have a defined CRS", call. = FALSE)
  
  gtype <- unique(as.character(sf::st_geometry_type(pts)))
  if (any(gtype == "MULTIPOINT")) {
    pts <- suppressWarnings(sf::st_cast(pts, "POINT"))
    gtype <- unique(as.character(sf::st_geometry_type(pts)))
  }
  if (!all(gtype == "POINT")) {
    message(sprintf("Existing shapefile geometry is [%s]; converting to interior points.", paste(gtype, collapse = ", ")))
    pts <- sf::st_point_on_surface(pts)
  }
  
  pts_ll <- sf::st_transform(pts, 4326)
  coords <- sf::st_coordinates(pts_ll)
  pts_ll[[lat_col]] <- round(coords[, 2], 6)
  pts_ll[[lon_col]] <- round(coords[, 1], 6)
  
  if (!(id_col %in% names(pts_ll))) {
    pts_ll[[id_col]] <- sprintf("%08d", seq_len(nrow(pts_ll)))
  } else {
    ids <- as.character(pts_ll[[id_col]])
    bad <- is.na(ids) | ids == "" | duplicated(ids)
    if (any(bad)) {
      message("ID column exists but has NA/blank/duplicates; regenerating sequential IDs.")
      pts_ll[[id_col]] <- sprintf("%08d", seq_len(nrow(pts_ll)))
    } else {
      pts_ll[[id_col]] <- sprintf("%08d", match(ids, unique(ids)))
    }
  }
  
  dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
  sf::st_write(pts_ll, output_path, append = FALSE, delete_layer = TRUE, quiet = TRUE)
  return(pts_ll)
}

#' Extend a .WTH file to target_end_year by repeating a historic reference block
#'
#' @export
extend_weather_repeat_single_ignore_partial <- function(f,
                                                        ref_start_year,
                                                        ref_end_year,
                                                        target_end_year,
                                                        verbose = TRUE) {
  lines <- readLines(f, warn = FALSE, encoding = "UTF-8")
  data_start_idx <- grep("^\\s*[0-9]+", lines)[1]
  if (is.na(data_start_idx)) return(NULL)
  header_lines <- lines[1:(data_start_idx - 1)]
  data_lines_raw <- lines[data_start_idx:length(lines)]
  
  data_lines_clean <- gsub("NA", " -99.0 ", data_lines_raw, fixed = TRUE)
  data_lines_clean <- gsub("NaN", " -99.0 ", data_lines_clean, fixed = TRUE)
  d <- tryCatch({
    read.table(text = data_lines_clean, header = FALSE, fill = TRUE,
               colClasses = "numeric", na.strings = c("-99", "-99.0", "-99.00"))
  }, error = function(e) {
    if (verbose) message("Failed to read file: ", f, " : ", conditionMessage(e))
    return(NULL)
  })
  if (is.null(d) || nrow(d) == 0) return(NULL)
  
  sample_date <- as.integer(d[1,1])
  if (nchar(as.character(sample_date)) <= 5) {
    year_format <- "YYDDD"
    get_year_from_code <- function(x) { yy <- floor(x / 1000); ifelse(yy < 80, 2000 + yy, 1900 + yy) }
    make_date_code <- function(y, doy) as.integer(sprintf("%05d", (y %% 100) * 1000 + doy))
    date_width_fmt <- "%05d"
  } else {
    year_format <- "YYYYDDD"
    get_year_from_code <- function(x) floor(x / 1000)
    make_date_code <- function(y, doy) as.integer(sprintf("%07d", y * 1000 + doy))
    date_width_fmt <- "%07d"
  }
  
  is_leap <- function(yr) (yr %% 4 == 0 & yr %% 100 != 0) | (yr %% 400 == 0)
  
  raw_dates <- as.integer(d[,1])
  years_present <- get_year_from_code(raw_dates)
  doys_present  <- raw_dates %% 1000
  d$YEAR <- years_present
  d$DOY  <- doys_present

  if (ref_end_year < ref_start_year) {
    stop("ref_end_year must be greater than or equal to ref_start_year", call. = FALSE)
  }
  
  years_unique <- sort(unique(d$YEAR))
  complete_years <- c()
  for (yr in years_unique) {
    expected_days <- if (is_leap(yr)) 366 else 365
    actual_doys <- d$DOY[d$YEAR == yr & !is.na(d$DOY)]
    if (length(actual_doys) == expected_days &&
        !anyDuplicated(actual_doys) &&
        identical(sort(as.integer(actual_doys)), seq_len(expected_days))) {
      complete_years <- c(complete_years, yr)
    }
  }

  eligible <- complete_years[complete_years >= ref_start_year & complete_years <= ref_end_year]
  if (length(eligible) == 0L) {
    stop(sprintf("No complete, duplicate-free reference year in %d-%d: %s",
                 ref_start_year, ref_end_year, f), call. = FALSE)
  }
  chosen_ref_year <- max(eligible)
  last_full_year <- max(complete_years)
  # Ignore a trailing partial year instead of retaining it ahead of repeated data.
  d_trunc <- d[d$YEAR <= last_full_year, , drop = FALSE]
  
  canonical_colnames <- names(d_trunc)
  canonical_body_colnames <- setdiff(canonical_colnames, c("YEAR", "DOY"))
  canonical_ncol <- length(canonical_body_colnames)
  
  coerce_block_to_canonical <- function(block_df, src_name = "<block>") {
    if ("YEAR" %in% names(block_df)) block_df$YEAR <- NULL
    if ("DOY"  %in% names(block_df)) block_df$DOY  <- NULL
    
    if (ncol(block_df) < canonical_ncol) {
      n_missing <- canonical_ncol - ncol(block_df)
      filler <- as.data.frame(matrix(-99.0, nrow = nrow(block_df), ncol = n_missing))
      names_existing <- names(block_df)
      missing_names <- canonical_body_colnames[(length(names_existing) + 1):canonical_ncol]
      names(filler) <- missing_names
      out <- cbind(block_df, filler)
      names(out) <- canonical_body_colnames
      return(out)
    } else if (ncol(block_df) > canonical_ncol) {
      out <- block_df[, seq_len(canonical_ncol), drop = FALSE]
      names(out) <- canonical_body_colnames
      return(out)
    } else {
      out <- block_df
      names(out) <- canonical_body_colnames
      return(out)
    }
  }
  
  ref_block <- d[d$YEAR == chosen_ref_year, , drop = FALSE]
  
  ref_block_body <- coerce_block_to_canonical(ref_block, src_name = "ref_block")
  base_df <- d_trunc[, canonical_body_colnames, drop = FALSE]
  base_df <- coerce_block_to_canonical(base_df, src_name = "base_df")
  
  if (last_full_year >= target_end_year) {
    final_df <- base_df
  } else {
    years_to_add <- seq(last_full_year + 1, target_end_year)
    
    ref_DOY <- as.integer(ref_block[,1]) %% 1000
    ref_year_in_block <- get_year_from_code(as.integer(ref_block[1,1]))
    ref_dates_vec <- as.Date(paste0(ref_year_in_block, "-01-01")) + (ref_DOY - 1)
    ref_mmdd <- format(ref_dates_vec, "%m-%d")
    ref_vals_allcols <- ref_block_body
    
    added_list <- list()
    for (tgt_year in years_to_add) {
      tgt_expected_days <- if (is_leap(tgt_year)) 366 else 365
      tgt_dates <- as.Date(paste0(tgt_year, "-01-01")) + (0:(tgt_expected_days - 1))
      tgt_mmdd <- format(tgt_dates, "%m-%d")
      
      idx_rows <- integer(length(tgt_mmdd))
      for (i in seq_along(tgt_mmdd)) {
        mm <- tgt_mmdd[i]
        candidates <- which(ref_mmdd == mm)
        if (length(candidates) > 0) {
          idx_rows[i] <- candidates[1]
        } else if (mm == "02-29") {
          c2 <- which(ref_mmdd == "02-28")
          if (length(c2) == 0L) stop("Reference year lacks February 28", call. = FALSE)
          idx_rows[i] <- c2[1]
        } else {
          stop(sprintf("Complete reference year unexpectedly lacks calendar day %s", mm), call. = FALSE)
        }
      }
      
      temp_out <- ref_vals_allcols[idx_rows, , drop = FALSE]
      temp_out <- coerce_block_to_canonical(temp_out, src_name = paste0("temp_out_", tgt_year))
      
      new_date_codes <- vapply(1:tgt_expected_days, function(doy) make_date_code(tgt_year, doy), integer(1))
      temp_out[, 1] <- as.integer(new_date_codes)
      
      temp_out[is.na(temp_out)] <- -99.0
      added_list[[length(added_list) + 1]] <- temp_out
    }
    
    final_df <- rbind(base_df, do.call(rbind, added_list))
  }
  
  final_df[,1] <- as.integer(final_df[,1])
  date_col_str <- sprintf(date_width_fmt, as.integer(final_df[,1]))
  if (ncol(final_df) >= 2) {
    val_cols_list <- lapply(final_df[, -1, drop = FALSE], function(col) {
      col[is.na(col)] <- -99.0
      sprintf("%6.1f", as.numeric(col))
    })
    formatted_body <- do.call(paste, c(list(date_col_str), val_cols_list, list(sep = "")))
  } else {
    formatted_body <- date_col_str
  }
  
  partial <- tempfile(pattern = paste0(basename(f), "."), tmpdir = dirname(f), fileext = ".partial")
  on.exit(if (file.exists(partial)) unlink(partial), add = TRUE)
  writeLines(c(header_lines, formatted_body), con = partial, useBytes = TRUE)
  if (!file.rename(partial, f)) {
    stop(sprintf("Could not atomically replace weather file: %s", f), call. = FALSE)
  }
  return(TRUE)
}

safe_write_lines <- function(text, path, max_attempts = 5, delay_sec = 1) {
  for (attempt in seq_len(max_attempts)) {
    ok <- tryCatch({
      con <- file(path, open = "w", encoding = "UTF-8")
      writeLines(text, con = con)
      close(con)
      TRUE
    }, error = function(e) {
      if (attempt == max_attempts) {
        stop(sprintf("Failed to write to %s after %d attempts: %s", path, max_attempts, conditionMessage(e)), call. = FALSE)
      }
      Sys.sleep(delay_sec)
      FALSE
    })
    if (ok) break
  }
  invisible(path)
}

#' Write a DSSAT batch file for experiment-mode treatment runs
#'
#' Mirrors Python `write_dssbatch`. The FileX value intentionally starts in
#' column 1; a leading blank can crash DSSAT's Fortran substring logic.
#'
#' @export
write_dssbatch <- function(experiment_file, trtno_list,
                           batch_path, run_mode = "experiment") {
  mode_tag <- if (identical(run_mode, "experiment")) "EXPERIMENT" else "SEQUENCE"
  header <- c(
    sprintf("$BATCH(%s)", mode_tag),
    "!",
    "@ FILEX                                                                                        TRTNO RP SQ OP CO"
  )
  fname <- basename(experiment_file)
  if (nchar(fname, type = "bytes") > 92L || !identical(iconv(fname, to = "ASCII"), fname) || grepl("[\r\n]", fname)) {
    stop("DSSAT FileX basename must be ASCII and at most 92 characters", call. = FALSE)
  }
  trt_vec <- as.integer(unlist(trtno_list, use.names = FALSE))
  lines <- vapply(trt_vec, function(trt) {
    sprintf("%-93s%6d  1  0  1  0", fname, trt)
  }, character(1))

  safe_write_lines(c(header, lines), batch_path)
}

#' Write a DSSAT batch file for sequence-mode runs
#'
#' @export
write_dssbatch_sequence <- function(experiment_file, trt,
                                    seq_start, seq_end,
                                    batch_path) {
  fname <- basename(experiment_file)
  if (nchar(fname, type = "bytes") > 92L || !identical(iconv(fname, to = "ASCII"), fname) || grepl("[\r\n]", fname)) {
    stop("DSSAT FileX basename must be ASCII and at most 92 characters", call. = FALSE)
  }
  if (seq_end < seq_start) stop("seq_end must be >= seq_start", call. = FALSE)
  header <- c(
    "$BATCH(SEQUENCE)",
    "!",
    "@ FILEX                                                                                        TRTNO RP SQ OP CO"
  )
  # Column layout is load-bearing in SEQUENCE mode. CSM.for reads the treatment
  # fields from CHARTEST(93:113) with FORMAT(3(1X,I6)): cols 94-99 = TRTNO,
  # 101-106 = RP, 108-113 = ROTNO/SQ. The SQ (rotation) field MUST land in
  # 108-113; otherwise sequence mode mis-reads the rotation and aborts with
  # libgfortran IOSTAT 5010 (read overflow) while parsing the FileX. FileX still
  # starts in column 1 (a leading blank breaks CSM's substring math).
  #   <92 FileX> SP <TRTNO i6> SP <RP i6> SP <SQ i6> SP <OP i6> SP <CO i6>
  lines <- vapply(seq.int(seq_start, seq_end), function(sq) {
    sprintf("%-92s %6d %6d %6d %6d %6d", fname, as.integer(trt), 1L,
            as.integer(sq), 1L, 0L)
  }, character(1))

  safe_write_lines(c(header, lines), batch_path)
}

#' Normalize a treatment selection into an ordered, deduplicated integer vector.
#'
#' Mirrors the Python `_normalize_treatment_list`. Accepts either a contiguous
#' `treatment_start`..`treatment_end` range or an explicit (possibly
#' non-contiguous) `treatment_list`. The legacy `treatments` argument is
#' deprecated and may not be combined with `treatment_list`.
#'
#' @export
normalize_treatment_list <- function(treatment_start, treatment_end,
                                     treatment_list = NULL,
                                     treatments = NULL) {
  has_list <- !is.null(treatment_list) && length(treatment_list) > 0
  has_legacy <- !is.null(treatments) && length(treatments) > 0
  if (has_list && has_legacy) {
    stop("Use only one explicit treatment selector: 'treatment_list'. ",
         "The legacy 'treatments' argument is ambiguous and is ignored by new configs.",
         call. = FALSE)
  }
  if (has_legacy) {
    warning("'treatments' is deprecated; use 'treatment_list' for explicit treatment IDs.",
            call. = FALSE)
    treatment_list <- treatments
    has_list <- TRUE
  }
  if (has_list) {
    raw <- suppressWarnings(as.numeric(unlist(treatment_list, use.names = FALSE)))
    if (any(!is.finite(raw)) || any(raw != floor(raw))) {
      stop("Treatment IDs must be finite integers.", call. = FALSE)
    }
    trt_vec <- as.integer(raw)
  } else {
    raw_start <- suppressWarnings(as.numeric(treatment_start)[1])
    raw_end <- suppressWarnings(as.numeric(treatment_end)[1])
    if (!is.finite(raw_start) || !is.finite(raw_end) ||
        raw_start != floor(raw_start) || raw_end != floor(raw_end)) {
      stop("treatment_start and treatment_end must be valid integers.", call. = FALSE)
    }
    start <- as.integer(raw_start); end <- as.integer(raw_end)
    if (end < start) {
      stop(sprintf("treatment_end (%d) must be >= treatment_start (%d).", end, start),
           call. = FALSE)
    }
    trt_vec <- seq.int(start, end)
  }
  trt_vec <- unique(trt_vec[!is.na(trt_vec)])
  if (!length(trt_vec)) {
    stop("No valid treatments selected. Set treatment_start/treatment_end or treatment_list.",
         call. = FALSE)
  }
  if (any(trt_vec < 1L)) {
    stop("Treatment IDs must be positive integers.", call. = FALSE)
  }
  trt_vec
}

#' Run DSSAT with captured stdout/stderr and fail-loud exit handling
#'
#' Mirrors Python `run_dssat`. `model` is optional for DSSAT builds that expect
#' calls such as `dscsm048 CRGRO048 B DSSBatch.V48`.
#'
#' @export
run_dssat <- function(run_dir, exe, run_mode_flag = "A", filex = "",
                      model = NULL, timeout = 0) {
  arg <- if (run_mode_flag %in% c("B", "Q", "N", "S")) {
    "DSSBatch.V48"
  } else if (!is.null(filex) && nzchar(filex)) {
    filex
  } else {
    "DSSBatch.V48"
  }

  exe_path <- exe
  has_dir <- grepl("[/\\\\]", exe)
  if (!has_dir) {
    resolved <- Sys.which(exe)
    if (nzchar(resolved)) exe_path <- resolved
  }
  if (has_dir && !file.exists(exe_path)) {
    stop(sprintf("DSSAT executable not found: %s", exe_path), call. = FALSE)
  }

  args <- c(run_mode_flag, arg)
  if (!is.null(model) && nzchar(as.character(model))) {
    args <- c(as.character(model), run_mode_flag, arg)
  }

  old_wd <- getwd()
  setwd(run_dir)
  on.exit(setwd(old_wd), add = TRUE)

  out_file <- sprintf("dssat_%s_stdout_stderr.log", run_mode_flag)
  output <- tryCatch(
    withCallingHandlers(
      system2(exe_path, args = args, stdout = TRUE, stderr = TRUE, timeout = timeout),
      warning = function(w) invokeRestart("muffleWarning")
    ),
    error = function(e) structure(conditionMessage(e), status = 1L)
  )
  status <- attr(output, "status")
  if (is.null(status)) status <- 0L
  if (length(output)) {
    try(append_utf8(out_file, paste(output, collapse = "\n")), silent = TRUE)
  }
  if (!identical(as.integer(status), 0L)) {
    tail_msg <- if (length(output)) paste(tail(output, 12), collapse = " | ") else "<no stdout/stderr captured>"
    stop(sprintf("DSSAT exited with status %s in mode %s using %s. Log: %s. Tail: %s",
                 status, run_mode_flag, arg, file.path(run_dir, out_file), tail_msg),
         call. = FALSE)
  }
  invisible(output)
}

#' Run DSSAT Simulation for a single point (R Implementation)
#'
#' @export
run_simulation <- function(ID,
                           dssat_run_dir,
                           crop_extension,
                           template_file_name,
                           template_file_path,
                           run_mode,
                           treatment_start,
                           treatment_end,
                           sequence_start,
                           sequence_end,
                           weather_start_year,
                           weather_end_year,
                           dssat_exe_path,
                           cleanup_run_folders = FALSE,
                           points_df = NULL,
                           treatment_list = NULL,
                           treatments = NULL,
                           timeout = 0) {
  old_dssat_option <- getOption("DSSAT.CSM")
  options(DSSAT.CSM = dssat_exe_path)
  on.exit(options(DSSAT.CSM = old_dssat_option), add = TRUE)

  point_dir <- file.path(dssat_run_dir, ID)
  if (!dir.exists(point_dir)) dir.create(point_dir, recursive = TRUE)
  
  orig_wd <- getwd()
  tryCatch({ setwd(point_dir) }, error = function(e) return(NULL))
  on.exit(setwd(orig_wd), add = TRUE)

  # Per-point error log. message() from parLapply workers is NEVER shown in the
  # parent console, so a failing point would otherwise vanish silently (no
  # results_<ID>.csv, no error). Writing into the point folder survives worker
  # isolation and gives a durable breadcrumb to diagnose from.
  log_run_error <- function(msg) {
    line <- sprintf("[%s] ID %s: %s", format(Sys.time()), ID, msg)
    try(append_utf8("_run_error.log", line), silent = TRUE)
    message(line)  # still emit for interactive / sequential runs
  }

  trt_vec <- normalize_treatment_list(treatment_start, treatment_end, treatment_list, treatments)

  template_ext <- tools::file_ext(template_file_name)
  experiment_file <- basename(template_file_name)
  if (!file.exists(experiment_file)) {
    # Copy from template path if not present in folder
    if (file.exists(template_file_path)) {
      copied <- file.copy(template_file_path, experiment_file, overwrite = TRUE)
      if (!copied) stop("Failed to copy requested FileX template", call. = FALSE)
    } else {
      stop(sprintf("Template file not found: %s", template_file_path), call. = FALSE)
    }
  }
  
  results_template <- data.frame(
    point_id = character(), run_number = numeric(), treatment = numeric(), crop_code = character(),
    latitude = numeric(), longitude = numeric(), weather_station_id = character(), soil_profile_id = character(),
    dssat_file_id = character(), dssat_description = character(), planting_date = numeric(), emergence_date = numeric(),
    harvest_date = numeric(), year_planting = numeric(), year_harvest = numeric(), top_weight_kg_ha = numeric(),
    final_grain_kg_ha = numeric(), removed_residue_kg_ha = numeric(), soil_organic_carbon_start_kg_C_ha = numeric(),
    soil_organic_carbon_end_kg_C_ha = numeric(), soil_organic_carbon_delta_kg_C_ha = numeric(),
    final_irrigation_applications_count = numeric(), final_irrigation_amount_mm = numeric(),       
    inorganic_n_applied_count = numeric(), inorganic_n_applied_kg_ha = numeric(), nitrate_leaching_kg_ha = numeric(),
    cumulative_net_co2_emissions_kg_CO2_ha = numeric(), cumulative_n2o_emissions_kg_N_ha = numeric(),
    stringsAsFactors = FALSE
  )
  results <- results_template
  
  read_supp_file <- function(fname) {
    if (file.exists(fname)) {
      d <- try(suppressWarnings(readr::read_csv(fname, show_col_types = FALSE,
                                                locale = readr::locale(encoding = "UTF-8"))),
               silent = TRUE)
      if (inherits(d, "try-error") || is.null(d) || nrow(d) == 0) return(NULL)
      return(d)
    }
    return(NULL)
  }
  
  tryCatch({
    
    # MODE A: EXPERIMENT 
    if (run_mode == "experiment") {
      batch_file_path <- file.path(getwd(), 'DSSBatch.V48')
      write_dssbatch(experiment_file, trt_vec, batch_file_path, run_mode = "experiment")
      run_dssat(".", dssat_exe_path, "B", timeout = timeout)

      if (!file.exists('summary.csv')) {
        has_summary_out <- file.exists("Summary.OUT")
        stop("DSSAT completed but produced no 'summary.csv'. ",
             if (has_summary_out) "Summary.OUT exists, so the FileX may still be configured for ASCII output. " else "",
             "For CSV parsing, the experiment file's OUTPUTS line must end in FMOPT = 'C'. ",
             "Also check ERROR.OUT, WARNING.OUT, INFO.OUT, and dssat_B_stdout_stderr.log in this folder.",
             call. = FALSE)
      }
      summary <- suppressWarnings(readr::read_csv('summary.csv', show_col_types = FALSE,
                                                  locale = readr::locale(encoding = "UTF-8")))
      
      if (is.null(summary) || nrow(summary) == 0) {
        stop("DSSAT produced an empty summary.csv; no result rows can be inferred.", call. = FALSE)
      } else {
        summary$PYEAR <- substr(summary$PDAT, 1, 4)
      }
      
      master_runs <- dplyr::tibble(RUNNO = summary$RUNNO)
      soil_org <- read_supp_file('soilorg.csv')
      if (!is.null(soil_org)) {
        soil_org_sum <- soil_org %>% dplyr::group_by(RUN) %>% dplyr::summarise(SOMCT_start = head(SOMCT, 1), SOMCT_end = tail(SOMCT, 1)) %>% dplyr::rename(RUNNO = RUN)
        soil_organic_summarized <- dplyr::left_join(master_runs, soil_org_sum, by = "RUNNO")
      } else { soil_organic_summarized <- master_runs %>% dplyr::mutate(SOMCT_start=NA, SOMCT_end=NA) }
      
      soil_ni <- read_supp_file('soilni.csv')
      if (!is.null(soil_ni)) {
        soil_ni_sum <- soil_ni %>% dplyr::group_by(RUN) %>% dplyr::summarise(NAPC = tail(NAPC, 1), NLCC = tail(NLCC, 1), `NI#M` = tail(`NI#M`,1)) %>% dplyr::rename(RUNNO = RUN)
        soilnitrogen_summarized <- dplyr::left_join(master_runs, soil_ni_sum, by = "RUNNO")
      } else { soilnitrogen_summarized <- master_runs %>% dplyr::mutate(NAPC=NA, NLCC=NA, `NI#M`=NA) }
      
      soil_wat <- read_supp_file('soilwat.csv')
      if (!is.null(soil_wat)) {
        soil_wat_sum <- soil_wat %>% dplyr::group_by(RUN) %>% dplyr::summarise(`IR#C` = tail(`IR#C`, 1), IRRC = tail(IRRC, 1)) %>% dplyr::rename(RUNNO = RUN)
        irrigation_summarized <- dplyr::left_join(master_runs, soil_wat_sum, by = "RUNNO")
      } else { irrigation_summarized <- master_runs %>% dplyr::mutate(`IR#C`=NA, IRRC=NA) }
      
      run_results <- data.frame(
        point_id = ID, run_number = summary$RUNNO, treatment = summary$TRNO, crop_code = summary$CR,
        latitude = summary$LAT, longitude = summary$LONG, weather_station_id = summary$WSTA,
        soil_profile_id = summary$SOIL_ID, dssat_file_id = summary$EXNAME, dssat_description = summary$TNAM,
        planting_date = summary$PDAT, emergence_date = summary$EDAT, harvest_date = summary$HDAT,
        year_planting = as.integer(summary$PYEAR), year_harvest = summary$HYEAR, top_weight_kg_ha = summary$CWAM,
        final_grain_kg_ha = summary$HWAM, removed_residue_kg_ha = summary$BWAH,
        soil_organic_carbon_start_kg_C_ha = soil_organic_summarized$SOMCT_start,
        soil_organic_carbon_end_kg_C_ha = soil_organic_summarized$SOMCT_end,
        soil_organic_carbon_delta_kg_C_ha = soil_organic_summarized$SOMCT_end - soil_organic_summarized$SOMCT_start,
        final_irrigation_applications_count = irrigation_summarized$`IR#C`, final_irrigation_amount_mm= irrigation_summarized$IRRC,
        inorganic_n_applied_count = soilnitrogen_summarized$`NI#M`, inorganic_n_applied_kg_ha = soilnitrogen_summarized$NAPC,
        nitrate_leaching_kg_ha = soilnitrogen_summarized$NLCC, cumulative_net_co2_emissions_kg_CO2_ha = summary$CO2EM,
        cumulative_n2o_emissions_kg_N_ha = summary$N2OEM
      )
      results <- rbind(results, run_results)
      
      # MODE B: SEQUENCE 
    } else if (run_mode == "sequence") {
      for (trt in trt_vec) {
        batch_file_path <- file.path(getwd(), 'DSSBatch.V48')
        write_dssbatch_sequence(experiment_file, trt, sequence_start, sequence_end, batch_file_path)
        run_dssat(".", dssat_exe_path, "Q", timeout = timeout)
        if (!file.exists('summary.csv')) {
          stop(sprintf("trt %d: DSSAT produced no summary.csv", trt), call. = FALSE)
        }
        summary <- suppressWarnings(readr::read_csv('summary.csv', show_col_types = FALSE,
                                                    locale = readr::locale(encoding = "UTF-8")))

        if (!is.null(summary) && nrow(summary) > 0) {
          summary$PYEAR <- substr(summary$PDAT, 1, 4)
          master_runs <- dplyr::tibble(RUNNO = summary$RUNNO)

          soil_org <- read_supp_file('soilorg.csv')
          if (!is.null(soil_org)) {
            soil_org_sum <- soil_org %>% dplyr::group_by(RUN) %>% dplyr::summarise(SOMCT_start = head(SOMCT, 1), SOMCT_end = tail(SOMCT, 1)) %>% dplyr::rename(RUNNO = RUN)
            soil_organic_summarized <- dplyr::left_join(master_runs, soil_org_sum, by = "RUNNO")
          } else { soil_organic_summarized <- master_runs %>% dplyr::mutate(SOMCT_start=NA, SOMCT_end=NA) }

          soil_ni <- read_supp_file('soilni.csv')
          if (!is.null(soil_ni)) {
            soil_ni_sum <- soil_ni %>% dplyr::group_by(RUN) %>% dplyr::summarise(NAPC = tail(NAPC, 1), NLCC = tail(NLCC, 1), `NI#M` = tail(`NI#M`,1)) %>% dplyr::rename(RUNNO = RUN)
            soilnitrogen_summarized <- dplyr::left_join(master_runs, soil_ni_sum, by = "RUNNO")
          } else { soilnitrogen_summarized <- master_runs %>% dplyr::mutate(NAPC=NA, NLCC=NA, `NI#M`=NA) }

          soil_wat <- read_supp_file('soilwat.csv')
          if (!is.null(soil_wat)) {
            soil_wat_sum <- soil_wat %>% dplyr::group_by(RUN) %>% dplyr::summarise(`IR#C` = tail(`IR#C`, 1), IRRC = tail(IRRC, 1)) %>% dplyr::rename(RUNNO = RUN)
            irrigation_summarized <- dplyr::left_join(master_runs, soil_wat_sum, by = "RUNNO")
          } else { irrigation_summarized <- master_runs %>% dplyr::mutate(`IR#C`=NA, IRRC=NA) }

          seq_results <- data.frame(
            point_id = ID, run_number = summary$RUNNO, treatment = summary$TRNO, crop_code = summary$CR,
            latitude = summary$LAT, longitude = summary$LONG, weather_station_id = summary$WSTA,
            soil_profile_id = summary$SOIL_ID, dssat_file_id = summary$EXNAME, dssat_description = summary$TNAM,
            planting_date = summary$PDAT, emergence_date = summary$EDAT, harvest_date = summary$HDAT,
            year_planting = as.integer(summary$PYEAR), year_harvest = summary$HYEAR, top_weight_kg_ha = summary$CWAM,
            final_grain_kg_ha = summary$HWAM, removed_residue_kg_ha = summary$BWAH,
            soil_organic_carbon_start_kg_C_ha = soil_organic_summarized$SOMCT_start,
            soil_organic_carbon_end_kg_C_ha = soil_organic_summarized$SOMCT_end,
            soil_organic_carbon_delta_kg_C_ha = soil_organic_summarized$SOMCT_end - soil_organic_summarized$SOMCT_start,
            final_irrigation_applications_count = irrigation_summarized$`IR#C`, final_irrigation_amount_mm = irrigation_summarized$IRRC,
            inorganic_n_applied_count = soilnitrogen_summarized$`NI#M`, inorganic_n_applied_kg_ha = soilnitrogen_summarized$NAPC,
            nitrate_leaching_kg_ha = soilnitrogen_summarized$NLCC, cumulative_net_co2_emissions_kg_CO2_ha = summary$CO2EM,
            cumulative_n2o_emissions_kg_N_ha = summary$N2OEM
          )
          results <- rbind(results, seq_results)
        }
      } 
    } else {
      stop("run_mode must be either 'experiment' or 'sequence'", call. = FALSE)
    }
    
    # Coordinate overwrite fallback
    if (!is.null(points_df) && nrow(results) > 0) {
      pt_row <- points_df[points_df[[POINT_ID_COLUMN]] == ID, ]
      if (nrow(pt_row) > 0) {
        results$latitude <- as.numeric(pt_row[[LAT_COLUMN]])
        results$longitude <- as.numeric(pt_row[[LONG_COLUMN]])
      }
    }
    
    if (nrow(results) > 0) readr::write_csv(results, paste0("results_", ID, ".csv"), na = "")

    # NOTE: run-folder cleanup is intentionally NOT done here. The pipelines
    # build the combined summary CSV by re-reading each point's results_<ID>.csv
    # from disk AFTER all points finish, so deleting the folder now would race
    # the combine step and yield an empty summary. The `cleanup_run_folders`
    # argument is kept for backward compatibility but is a no-op; deletion is
    # handled by the calling pipeline once the combined CSV has been written
    # (see dssat_main_pipeline.R / .py). This also matches the Python engine,
    # whose per-point worker never deletes its own folder.

    return(results)
    
  }, error = function(e) {
    log_run_error(sprintf("FATAL: %s", conditionMessage(e)))
    stop(e)
  })
}
