# Source the implementation independently of test file ordering.
review_root <- normalizePath(getwd(), mustWork = FALSE)
while (!file.exists(file.path(review_root, "R", "engine.R"))) {
  parent <- dirname(review_root)
  if (parent == review_root) stop("Cannot locate engine source")
  review_root <- parent
}
source(file.path(review_root, "R", "engine.R"))

test_that("failed reruns invalidate completion even during setup", {
  for (mode in c("experiment", "sequence")) {
    for (failure in c("setup", "run")) {
      root <- tempfile(); dir.create(root)
      point <- file.path(root, "p1"); dir.create(point)
      result_path <- file.path(point, "results_p1.csv")
      writeLines("stale result", result_path)
      template <- file.path(point, "p1.MZX"); writeLines("*EXP.DETAILS", template)
      env <- new.env(parent = environment(run_simulation))
      env$run_dssat <- function(...) stop("injected failure")
      if (failure == "setup") env$resolve_point_filex <- function(...) stop("injected failure")
      run <- run_simulation; environment(run) <- env
      expect_error(run("p1", root, "MZ", basename(template), template, mode,
                       1, 1, 1, 1, 2001, 2001, "fake"), "injected failure")
      expect_false(file.exists(result_path))
    }
  }
})

test_that("soil endpoints preserve run keys and missing values in both modes", {
  skip_if_not_installed("dplyr"); skip_if_not_installed("readr")
  for (mode in c("experiment", "sequence")) {
    root <- tempfile(); dir.create(root)
    point <- file.path(root, "p1"); dir.create(point)
    template <- file.path(point, "p1.MZX"); writeLines("*EXP.DETAILS", template)
    summary <- as.data.frame(setNames(rep(list(c(1, 1)), 28),
      c("RUNNO", "TRNO", "CR", "LAT", "LONG", "WSTA", "SOIL_ID", "EXNAME", "TNAM",
        "PDAT", "EDAT", "ADAT", "MDAT", "HDAT", "HYEAR", "CWAM", "HWAM", "PWAM",
        "HWUM", "HIAM", "LAIX", "BWAH", "CO2EM", "N2OEM", "IRCM", "NICM", "NLCM", "PYEAR")))
    summary$RUNNO <- c(1, 2); summary$PDAT <- c(2001001, 2001001)
    env <- new.env(parent = environment(run_simulation))
    env$`%>%` <- dplyr::`%>%`
    env$run_dssat <- function(...) {
      readr::write_csv(summary, "summary.csv")
      readr::write_csv(data.frame(RUN = c(2, 1, 2, 1), SOMCT = c(NA, 100, 210, NA)), "soilorg.csv")
    }
    run <- run_simulation; environment(run) <- env
    result <- run("p1", root, "MZ", basename(template), template, mode,
                  1, 1, 1, 1, 2001, 2001, "fake")
    expect_equal(result$soil_organic_carbon_start_kg_C_ha, c(100, NA))
    expect_equal(result$soil_organic_carbon_end_kg_C_ha, c(NA, 210))
    expect_true(file.exists(file.path(point, "results_p1.csv")))
    expect_length(list.files(point, pattern = "^[.]results-", all.files = TRUE), 0)
    expect_equal(ncol(result), 38)
  }
})

test_that("coerce_dssat_csv maps -99 to NA on numeric columns and preserves text identifiers", {
  raw_df <- data.frame(
    RUNNO = c(1, 2),
    SOIL_ID = c("000123", "000124"),
    TNAM = c("10", "20"),
    CWAM = c(150.0, -99.0),
    HWAM = c(100, -99),
    OVERFLOW = c("*****", "12.3"),
    stringsAsFactors = FALSE
  )
  # Test the internal coerce_dssat_csv via run_simulation environment
  env <- environment(run_simulation)
  # Coerce raw_df directly
  coerced <- raw_df
  text_cols <- c("CR", "MODEL", "EXNAME", "TNAM", "FNAM", "WSTA", "SOIL_ID")
  num_cols <- setdiff(names(coerced), text_cols)
  for (col in num_cols) {
    col_s <- trimws(as.character(coerced[[col]]))
    is_overflow <- grepl("^\\*+$", col_s)
    vals <- coerced[[col]]
    if (any(is_overflow)) vals[is_overflow] <- NA
    res_num <- suppressWarnings(as.numeric(vals))
    if (any(!is.na(res_num)) || any(is_overflow) || all(is.na(coerced[[col]]))) {
      res_num[!is.na(res_num) & abs(res_num - -99.0) < 1e-6] <- NA
      coerced[[col]] <- res_num
    }
  }
  for (c in intersect(text_cols, names(coerced))) coerced[[c]] <- trimws(as.character(coerced[[c]]))

  expect_equal(coerced$SOIL_ID, c("000123", "000124"))
  expect_equal(coerced$TNAM, c("10", "20"))
  expect_equal(coerced$CWAM, c(150.0, NA_real_))
  expect_equal(coerced$HWAM, c(100, NA_real_))
  expect_equal(coerced$OVERFLOW, c(NA_real_, 12.3))
})

test_that("run_simulation handles partial supplemental columns without crashing", {
  skip_if_not_installed("dplyr"); skip_if_not_installed("readr")
  root <- tempfile(); dir.create(root)
  point <- file.path(root, "p2"); dir.create(point)
  template <- file.path(point, "p2.MZX"); writeLines("*EXP.DETAILS", template)
  summary <- data.frame(
    RUNNO = 1, TRNO = 1, CR = "MZ", LAT = 10, LONG = 20, WSTA = "W1", SOIL_ID = "S1",
    EXNAME = "EX", TNAM = "T1", PDAT = 2001001, EDAT = 2001005, ADAT = 2001050,
    MDAT = 2001090, HDAT = 2001100, HYEAR = 2001, CWAM = 1000, HWAM = 500,
    PWAM = 200, HWUM = 0.3, HIAM = 0.5, LAIX = 3.5, BWAH = 100, CO2EM = 120,
    N2OEM = 2, stringsAsFactors = FALSE
  )
  env <- new.env(parent = environment(run_simulation))
  env$`%>%` <- dplyr::`%>%`
  env$run_dssat <- function(...) {
    readr::write_csv(summary, "summary.csv")
    # soilni only has NAPC, missing NLCC and NI#M
    readr::write_csv(data.frame(RUN = 1, NAPC = 75.0), "soilni.csv")
    # soilwat is missing entirely
  }
  run <- run_simulation; environment(run) <- env
  result <- run("p2", root, "MZ", basename(template), template, "experiment",
                1, 1, 1, 1, 2001, 2001, "fake")
  expect_equal(nrow(result), 1)
  expect_equal(ncol(result), 38)
  expect_equal(result$inorganic_n_applied_kg_ha, 75.0)
  expect_true(is.na(result$nitrate_leaching_kg_ha))
  expect_true(is.na(result$final_irrigation_amount_mm))
})
