library(testthat)
library(sf)

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

test_boundary <- function() {
  st_sf(
    name = "test",
    geometry = st_sfc(st_polygon(list(rbind(
      c(0, 0), c(4000, 0), c(4000, 4000), c(0, 4000), c(0, 0)
    ))), crs = 5070)
  )
}

test_that("master-grid subsets are exact and stable", {
  master_path <- tempfile(fileext = ".gpkg")
  master <- create_master_grid_points(
    test_boundary(), 1000, master_path,
    grid_crs = "EPSG:5070", origin_x = 0, origin_y = 0
  )
  grid_2k <- derive_nested_grid_points(master, 2000, tempfile(fileext = ".gpkg"))
  grid_4k <- derive_nested_grid_points(master, 4000, tempfile(fileext = ".gpkg"))

  expect_equal(nrow(master), 25)
  expect_equal(nrow(grid_2k), 9)
  expect_equal(nrow(grid_4k), 4)
  expect_true(all(grid_4k$ID %in% grid_2k$ID))
  expect_true(all(grid_2k$ID %in% master$ID))
  expect_true(all(grid_2k$MROW %% 2 == 0))
  expect_true(all(grid_2k$MCOL %% 2 == 0))
  expect_true(all(grid_2k$MSPACE_M == 1000))
  expect_true(all(grid_2k$SAMP_M == 2000))
  expect_true(all(grid_2k$NEST_F == 2))
})

test_that("master-grid target spacing must be an integer multiple", {
  master <- create_master_grid_points(
    test_boundary(), 1000, tempfile(fileext = ".gpkg"), grid_crs = "EPSG:5070"
  )
  expect_error(
    derive_nested_grid_points(master, 1500, tempfile(fileext = ".gpkg")),
    "integer multiple"
  )
})

test_that("legacy independent grid remains available", {
  legacy <- create_grid_points(test_boundary(), 2000, tempfile(fileext = ".gpkg"))
  expect_gt(nrow(legacy), 0)
  expect_false("MROW" %in% names(legacy))
})
