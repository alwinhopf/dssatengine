# R parity test for treatment-list normalization.
# Mirrors tests/test_treatment_selection.py (R <-> Python parity, CONVENTIONS.md §3).
#
# Self-contained: sources R/engine.R directly so it runs without building the
# package (normalize_treatment_list uses only base R — no sf/DSSAT needed).

library(testthat)

# Locate R/engine.R by walking up from the current working directory, so the
# test runs both under testthat::test_dir("tests/testthat") and a bare Rscript.
find_engine <- function() {
  dir <- normalizePath(getwd(), mustWork = FALSE)
  for (i in seq_len(6)) {
    candidate <- file.path(dir, "R", "engine.R")
    if (file.exists(candidate)) return(candidate)
    parent <- dirname(dir)
    if (identical(parent, dir)) break
    dir <- parent
  }
  stop("Could not locate R/engine.R relative to ", getwd())
}

source(find_engine())

test_that("contiguous treatment range expands inclusively", {
  expect_equal(normalize_treatment_list(2, 4), c(2L, 3L, 4L))
})

test_that("explicit non-contiguous treatment_list preserves order and dedupes", {
  expect_equal(
    normalize_treatment_list(1, 99, treatment_list = list(5, 1, 5, "10")),
    c(5L, 1L, 10L)
  )
})

test_that("reversed range fails clearly", {
  expect_error(normalize_treatment_list(4, 1), "treatment_end")
})

test_that("non-positive treatment IDs are rejected", {
  expect_error(
    normalize_treatment_list(1, 1, treatment_list = c(0, 1)),
    "positive integers"
  )
})

test_that("treatment_list and legacy treatments cannot be combined", {
  expect_error(
    normalize_treatment_list(1, 1, treatment_list = c(1), treatments = c(2)),
    "only one explicit treatment selector"
  )
})

test_that("write_dssbatch writes explicit treatments", {
  batch <- tempfile(fileext = ".V48")
  write_dssbatch("CARINATA1984.SQX", c(1L, 5L, 10L), batch,
                 run_mode = "experiment")
  text <- readLines(batch, warn = FALSE, encoding = "UTF-8")
  expect_true(any(grepl("CARINATA1984.SQX", text, fixed = TRUE)))
  expect_true(any(grepl("     1", text, fixed = TRUE)))
  expect_true(any(grepl("     5", text, fixed = TRUE)))
  expect_true(any(grepl("    10", text, fixed = TRUE)))
})

test_that("write_dssbatch_sequence places SQ in CSM's ROTNO columns 108-113", {
  # SEQUENCE mode reads CHARTEST(93:113) as 3(1X,I6): TRTNO@94-99, RP@101-106,
  # ROTNO/SQ@108-113. Wrong columns -> DSSAT aborts (IOSTAT 5010). Mirrors the
  # Python parity test.
  batch <- tempfile(fileext = ".V48")
  write_dssbatch_sequence("00000003.SQX", 2L, 1L, 3L, batch)
  text <- readLines(batch, warn = FALSE, encoding = "UTF-8")
  data <- text[startsWith(text, "00000003.SQX")]
  expect_equal(length(data), 3)
  for (i in seq_along(data)) {
    ln <- data[i]
    expect_equal(substr(ln, 94, 99), "     2")              # TRTNO
    expect_equal(substr(ln, 101, 106), "     1")            # RP
    expect_equal(substr(ln, 108, 113), sprintf("%6d", i))   # SQ/ROTNO
  }
})

test_that("file helpers match the Python public surface", {
  text <- tempfile(); safe_write_lines(c("one", "two"), text, delay_sec = 0)
  append_utf8(text, "three")
  expect_equal(readLines(text, warn = FALSE), c("one", "two", "three"))

  source <- tempfile(fileext = ".SQX"); target <- tempfile(fileext = ".SQX")
  writeLines(c("*TREATMENTS", "@N R O C TNAME", " 1 1 1 0 first",
               " 2 1 1 0 second", "*CULTIVARS"), source)
  write_sequence_phase_file(source, target, treatment = 2L, phase = 1L)
  rendered <- readLines(target, warn = FALSE)
  expect_true(any(grepl("second", rendered, fixed = TRUE)))
  expect_false(any(grepl("first", rendered, fixed = TRUE)))
  expect_error(write_sequence_phase_file(source, target, 9L, 1L),
               "No sequence treatment row")
})
