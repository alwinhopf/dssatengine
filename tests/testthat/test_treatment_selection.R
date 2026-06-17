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
