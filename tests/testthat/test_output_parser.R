# R parity tests for the DSSAT output parsers.
# Mirrors tests/test_output_parser.py (R <-> Python parity, CONVENTIONS.md §3).
#
# Self-contained: sources R/parser.R directly so it runs without building the
# package (the parsers use only base R). Fixtures are shared with the Python
# tests under tests/fixtures/.

library(testthat)

find_file <- function(rel) {
  dir <- normalizePath(getwd(), mustWork = FALSE)
  for (i in seq_len(6)) {
    candidate <- file.path(dir, rel)
    if (file.exists(candidate)) return(candidate)
    parent <- dirname(dir)
    if (identical(parent, dir)) break
    dir <- parent
  }
  stop("Could not locate ", rel, " relative to ", getwd())
}

source(find_file(file.path("R", "parser.R")))
FIX <- dirname(find_file(file.path("tests", "fixtures", "PlantGro.OUT")))

test_that("yyddd_to_date handles YYYYDDD, YYDDD, and missing", {
  expect_equal(yyddd_to_date(2024264), as.Date("2024-09-20"))
  expect_equal(yyddd_to_date(24264), as.Date("2024-09-20"))
  expect_equal(yyddd_to_date(98001), as.Date("1998-01-01"))
  expect_true(is.na(yyddd_to_date(-99)))
  expect_true(is.na(yyddd_to_date(0)))
  expect_true(is.na(yyddd_to_date(2024400)))
})

test_that("parse_plantgro reads the wheat growth file", {
  df <- parse_plantgro(file.path(FIX, "PlantGro.OUT"))
  expect_gt(nrow(df), 0)
  for (col in c("YEAR", "DOY", "DAP", "GSTD", "LAID", "CWAD",
                "run", "treatment", "rotation", "date", "crop_model")) {
    expect_true(col %in% names(df), info = col)
  }
  expect_equal(df$YEAR[1], 2024)
  expect_equal(df$DOY[1], 264)
  expect_equal(df$date[1], as.Date("2024-09-20"))
  expect_equal(df$run[1], 1)
  expect_equal(df$crop_model[1], "CSCER048")
  expect_true(is.numeric(df$LAID))
  expect_true(any(is.na(df$SLAD)))   # all -99 early -> NA
})

test_that("PlantGro.OUT and plantgro.csv agree on shared columns", {
  out <- parse_plantgro(file.path(FIX, "PlantGro.OUT"))
  csv <- parse_csv(file.path(FIX, "plantgro.csv"))
  expect_equal(nrow(out), nrow(csv))
  # integer growth column matches exactly
  expect_true(all(abs(out$CWAD - csv$CWAD) < 1e-6 | (is.na(out$CWAD) & is.na(csv$CWAD))))
  # LAID rounded to 2 dp in .OUT vs full precision CSV -> display tolerance
  expect_true(all(abs(out$LAID - csv$LAID) < 0.02 | (is.na(out$LAID) & is.na(csv$LAID))))
})

test_that("other time-series files parse", {
  for (pair in list(c("PlantN.OUT", "NUAC"),
                    c("MgmtOps.OUT", "IRRC"),
                    c("GHG.OUT", "CO2EC"))) {
    df <- parse_timeseries(file.path(FIX, pair[1]))
    expect_gt(nrow(df), 0)
    expect_true(pair[2] %in% names(df), info = pair[1])
  }
})

test_that("real mode-Q rotation output splits into season blocks", {
  df <- parse_timeseries(file.path(FIX, "SeqRealPlantGro.OUT"))
  expect_gt(nrow(df), 0)
  expect_setequal(unique(df$run), c(1, 2, 3))
  yr_by_run <- tapply(df$YEAR, df$run, function(x) x[1])
  expect_equal(length(unique(yr_by_run)), 3)
  expect_equal(df$crop_model[1], "CRGRO048")
})

test_that("sequence rotation blocks keep per-crop columns", {
  df <- parse_timeseries(file.path(FIX, "SeqPlantGro.OUT"))
  expect_gt(nrow(df), 0)
  expect_setequal(unique(df$rotation), c(1, 2))
  expect_setequal(unique(df$run), c(1, 2))
  expect_setequal(unique(df$crop_model), c("MZCER048", "CRGRO048"))
  maize <- df[df$rotation == 1, ]
  soy <- df[df$rotation == 2, ]
  expect_true(all(is.na(maize$PODWT)))      # column only exists for soy block
  expect_true(any(!is.na(soy$PODWT)))
})

test_that("parse_summary reads fixed-width Summary.OUT incl spacey TNAM", {
  df <- parse_summary(file.path(FIX, "Summary.OUT"))
  expect_equal(nrow(df), 2)
  expect_equal(df$TNAM[1], "AG9010 - Rainfed")
  expect_equal(df$CR[1], "MZ")
  expect_equal(df$MODEL[1], "MZCER048")
  expect_equal(df$HWAM[1], 4329)
  expect_equal(df$CWAM[1], 10788)
  expect_true("PDAT_date" %in% names(df))
  expect_equal(df$PDAT_date[1], as.Date("2002-03-13"))
  expect_equal(df$RUNNO, c(1, 2))
})

test_that("parse_csv summary maps -99 sentinel to NA", {
  df <- parse_csv(file.path(FIX, "summary.csv"))
  expect_gt(nrow(df), 0)
  expect_true("HWAM" %in% names(df))
  expect_true("PDAT_date" %in% names(df))
  expect_true(all(is.na(df$EYLDH)))
})

test_that("dispatcher and directory reader work", {
  expect_gt(nrow(parse_dssat_output(file.path(FIX, "Summary.OUT"))), 0)
  expect_gt(nrow(parse_dssat_output(file.path(FIX, "PlantGro.OUT"))), 0)
  res <- read_run_directory(FIX, files = c("Summary.OUT", "PlantGro.OUT"))
  expect_setequal(names(res), c("summary", "plantgro"))
  auto <- read_run_directory(FIX)
  expect_true("plantgro" %in% names(auto))
  expect_true("plantn" %in% names(auto))
  expect_false("soilnibal" %in% names(auto))   # non-tabular skipped
})

test_that("read_run_directory includes CSV twins (CSV-mode runs)", {
  res <- read_run_directory(FIX)
  expect_true("somlitc_trailcomma" %in% names(res))   # csv-only stem
  expect_true("plantgro" %in% names(res))             # .OUT wins over .csv twin
  res_no <- read_run_directory(FIX, include_csv = FALSE)
  expect_false("somlitc_trailcomma" %in% names(res_no))
  expect_true("plantgro" %in% names(res_no))
})

test_that("parse_csv tolerates DSSAT trailing-comma rows", {
  df <- parse_csv(file.path(FIX, "somlitc_trailcomma.csv"))
  expect_gt(nrow(df), 0)
  expect_true(all(c("RUN", "CO2SC") %in% names(df)))
  expect_equal(df$YEAR[1], 1984)
})

test_that("Leaves.OUT (keyed by leaf number, not date) parses with run blocks", {
  df <- parse_timeseries(file.path(FIX, "Leaves.OUT"))
  expect_gt(nrow(df), 0)
  expect_true("LNUM" %in% names(df))
  expect_setequal(unique(df$run), c(1, 2, 3, 4, 5, 6))
  expect_equal(min(df$LNUM), 1)
})

test_that("balance summary parses one row per run", {
  df <- parse_dssat_output(file.path(FIX, "SoilNBalSum.OUT"))
  expect_equal(nrow(df), 6)
  expect_true(all(c("Run", "SNBAL") %in% names(df)))
  expect_equal(df$Run, c(1, 2, 3, 4, 5, 6))
})

test_that("6-treatment Summary parses all runs", {
  df <- parse_summary(file.path(FIX, "Summary6.OUT"))
  expect_equal(nrow(df), 6)
  expect_equal(df$RUNNO, c(1, 2, 3, 4, 5, 6))
  expect_gt(length(unique(df$HWAM)), 1)
})

test_that("missing and non-tabular files return empty", {
  expect_equal(nrow(parse_timeseries(file.path(FIX, "NOPE.OUT"))), 0)
  expect_equal(nrow(parse_summary(file.path(FIX, "nope.OUT"))), 0)
  expect_equal(nrow(parse_timeseries(file.path(FIX, "SoilNiBal.OUT"))), 0)
})
