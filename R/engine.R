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

#' Create a regular grid of points inside boundary_shape
#'
#' @export
create_grid_points <- function(boundary_shape, spacing_meters, output_path) {
  boundary_projected <- sf::st_transform(boundary_shape, 5070)
  bbox <- sf::st_bbox(boundary_projected)
  x_coords <- seq(floor(bbox$xmin), ceiling(bbox$xmax), by = spacing_meters)
  y_coords <- seq(floor(bbox$ymin), ceiling(bbox$ymax), by = spacing_meters)
  full_grid_df <- expand.grid(X = x_coords, Y = y_coords)
  grid_points_projected <- sf::st_as_sf(full_grid_df, coords = c("X", "Y"), crs = 5070)
  points_in_boundary_projected <- sf::st_filter(grid_points_projected, boundary_projected)
  
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
  
  gtype <- unique(as.character(sf::st_geometry_type(pts)))
  if (!all(gtype %in% c("POINT", "MULTIPOINT"))) {
    message(sprintf("Existing shapefile geometry is [%s]; converting to centroids.", paste(gtype, collapse = ", ")))
    pts <- sf::st_centroid(pts)
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
  lines <- readLines(f, warn = FALSE)
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
  
  years_unique <- sort(unique(d$YEAR))
  complete_years <- c()
  for (yr in years_unique) {
    expected_days <- if (is_leap(yr)) 366 else 365
    actual_days <- sum(d$YEAR == yr, na.rm = TRUE)
    if (actual_days == expected_days) complete_years <- c(complete_years, yr)
  }
  
  if (length(complete_years) > 0) {
    if (ref_end_year %in% complete_years) {
      chosen_ref_year <- ref_end_year
    } else {
      prior_candidates <- complete_years[complete_years <= ref_end_year]
      chosen_ref_year <- if (length(prior_candidates) > 0) max(prior_candidates) else max(complete_years)
    }
    last_full_year <- max(complete_years)
    d_trunc <- d[d$YEAR <= last_full_year, , drop = FALSE]
  } else {
    warning(sprintf("No complete years found in %s; falling back to first 365 rows.", f))
    chosen_ref_year <- ref_end_year
    n_take <- min(365, nrow(d))
    d_trunc <- d[1:n_take, , drop = FALSE]
    last_full_year <- get_year_from_code(as.integer(d_trunc[nrow(d_trunc), 1]))
  }
  
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
  
  if (year_format == "YYDDD") {
    yy_short <- chosen_ref_year %% 100
    ref_start_code <- yy_short * 1000
    ref_end_code   <- (yy_short + 1) * 1000
  } else {
    ref_start_code <- chosen_ref_year * 1000
    ref_end_code   <- (chosen_ref_year + 1) * 1000
  }
  ref_block <- d[d[,1] > ref_start_code & d[,1] < ref_end_code, , drop = FALSE]
  
  if (nrow(ref_block) == 0 && last_full_year %in% years_unique) {
    if (year_format == "YYDDD") {
      yy2 <- last_full_year %% 100
      ref_start_code <- yy2 * 1000
      ref_end_code   <- (yy2 + 1) * 1000
    } else {
      ref_start_code <- last_full_year * 1000
      ref_end_code   <- (last_full_year + 1) * 1000
    }
    ref_block <- d[d[,1] > ref_start_code & d[,1] < ref_end_code, , drop = FALSE]
  }
  if (nrow(ref_block) == 0) {
    ref_block <- d[1:min(365, nrow(d)), , drop = FALSE]
    tmp_first_year <- get_year_from_code(as.integer(ref_block[1,1]))
    chosen_ref_year <- tmp_first_year
  }
  
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
          if (length(c2) > 0) idx_rows[i] <- c2[1]
          else idx_rows[i] <- 1
        } else {
          found <- FALSE
          for (k in 1:5) {
            prev_mm <- format(tgt_dates[i] - k, "%m-%d")
            pidx <- which(ref_mmdd == prev_mm)
            if (length(pidx) > 0) { idx_rows[i] <- pidx[1]; found <- TRUE; break }
          }
          if (!found) idx_rows[i] <- 1
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
  
  writeLines(c(header_lines, formatted_body), f)
  return(TRUE)
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
                           points_df = NULL) {
  options(DSSAT.CSM = dssat_exe_path)
  
  point_dir <- file.path(dssat_run_dir, ID)
  if (!dir.exists(point_dir)) dir.create(point_dir, recursive = TRUE)
  
  orig_wd <- getwd()
  tryCatch({ setwd(point_dir) }, error = function(e) return(NULL))
  on.exit(setwd(orig_wd))

  # Per-point error log. message() from parLapply workers is NEVER shown in the
  # parent console, so a failing point would otherwise vanish silently (no
  # results_<ID>.csv, no error). Writing into the point folder survives worker
  # isolation and gives a durable breadcrumb to diagnose from.
  log_run_error <- function(msg) {
    line <- sprintf("[%s] ID %s: %s", format(Sys.time()), ID, msg)
    try(cat(line, "\n", file = "_run_error.log", append = TRUE), silent = TRUE)
    message(line)  # still emit for interactive / sequential runs
  }

  run_dssat_logged <- function(run_mode = "B", batch_file = "DSSBatch.V48") {
    out_file <- sprintf("dssat_%s_stdout_stderr.log", run_mode)
    output <- tryCatch(
      withCallingHandlers(
        system2(dssat_exe_path, args = c(run_mode, batch_file), stdout = TRUE, stderr = TRUE),
        warning = function(w) invokeRestart("muffleWarning")
      ),
      error = function(e) structure(conditionMessage(e), status = 1L)
    )
    status <- attr(output, "status")
    if (is.null(status)) status <- 0L
    if (length(output)) {
      try(cat(paste(output, collapse = "\n"), "\n", file = out_file, append = TRUE), silent = TRUE)
    }
    if (!identical(as.integer(status), 0L)) {
      tail_msg <- if (length(output)) paste(tail(output, 12), collapse = " | ") else "<no stdout/stderr captured>"
      stop(sprintf("DSSAT exited with status %s in mode %s using %s. Log: %s. Tail: %s",
                   status, run_mode, batch_file, out_file, tail_msg), call. = FALSE)
    }
    invisible(output)
  }

  template_ext <- tools::file_ext(template_file_name)
  experiment_file <- list.files(pattern = paste0("\\.", template_ext, "$"))[1]
  if (is.na(experiment_file)) {
    # Copy from template path if not present in folder
    if (file.exists(template_file_path)) {
      file.copy(template_file_path, ".", overwrite = TRUE)
      experiment_file <- basename(template_file_path)
    } else {
      return(NULL)
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
      d <- try(suppressWarnings(readr::read_csv(fname, show_col_types = FALSE)), silent = TRUE)
      if (inherits(d, "try-error") || is.null(d) || nrow(d) == 0) return(NULL)
      return(d)
    }
    return(NULL)
  }
  
  tryCatch({
    
    # MODE A: EXPERIMENT 
    if (run_mode == "experiment") {
      batch_file_path <- file.path(getwd(), 'DSSBatch.V48')
      DSSAT::write_dssbatch(x = experiment_file, trtno = treatment_start:treatment_end, file_name = batch_file_path)
      run_dssat_logged("B", basename(batch_file_path))

      if (!file.exists('summary.csv')) {
        has_summary_out <- file.exists("Summary.OUT")
        stop("DSSAT completed but produced no 'summary.csv'. ",
             if (has_summary_out) "Summary.OUT exists, so the FileX may still be configured for ASCII output. " else "",
             "For CSV parsing, the experiment file's OUTPUTS line must end in FMOPT = 'C'. ",
             "Also check ERROR.OUT, WARNING.OUT, INFO.OUT, and dssat_B_stdout_stderr.log in this folder.",
             call. = FALSE)
      }
      summary <- suppressWarnings(readr::read_csv('summary.csv', show_col_types = FALSE))
      
      if (is.null(summary) || nrow(summary) == 0) {
        treatments_vec <- treatment_start:treatment_end
        n_years <- (weather_end_year - weather_start_year)
        n_runs <- length(treatments_vec) * n_years
        summary <- dplyr::tibble(
          RUNNO = 1:n_runs, TRNO = rep(treatments_vec, each = n_years),
          PYEAR = rep(weather_start_year:(weather_end_year - 1), times = length(treatments_vec)),
          CR = NA_character_, LAT = NA_real_, LONG = NA_real_, WSTA = NA_character_,
          SOIL_ID = NA_character_, EXNAME = NA_character_, TNAM = NA_character_,
          PDAT = NA_real_, EDAT = NA_real_, HDAT = NA_real_, HYEAR = NA_real_,
          CWAM = NA_real_, HWAM = NA_real_, BWAH = NA_real_, CO2EM = NA_real_, N2OEM = NA_real_
        )
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
      for (trt in treatment_start:treatment_end) {
        seq_vec <- sequence_start:sequence_end
        n_seq <- length(seq_vec)
        batch_data <- dplyr::tibble(FILEX = experiment_file, TRTNO = rep(trt, n_seq), RP = 1, SQ = seq_vec, OP = 1, CO = 0)
        DSSAT::write_dssbatch(batch_data)
        run_dssat_logged("Q", "DSSBatch.V48")
        if (!file.exists('summary.csv')) {
          log_run_error(sprintf("trt %d: DSSAT completed but produced no 'summary.csv' (FMOPT must be 'C'; see ERROR.OUT, WARNING.OUT, INFO.OUT, dssat_Q_stdout_stderr.log).", trt))
          next
        }
        summary <- suppressWarnings(readr::read_csv('summary.csv', show_col_types = FALSE))

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
    return(NULL)
  })
}
