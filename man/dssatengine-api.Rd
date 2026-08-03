\name{dssatengine-api}
\alias{dssatengine-api}
\alias{append_utf8}
\alias{create_grid_points}
\alias{extend_weather_repeat_single_ignore_partial}
\alias{LAT_COLUMN}
\alias{load_existing_points}
\alias{LONG_COLUMN}
\alias{normalize_treatment_list}
\alias{parse_csv}
\alias{parse_dssat_output}
\alias{parse_evaluate}
\alias{parse_plantgro}
\alias{parse_plantn}
\alias{parse_summary}
\alias{parse_timeseries}
\alias{POINT_ID_COLUMN}
\alias{read_run_directory}
\alias{run_dssat}
\alias{run_simulation}
\alias{safe_write_lines}
\alias{write_dssbatch}
\alias{write_dssbatch_sequence}
\alias{write_sequence_phase_file}
\alias{yyddd_to_date}
\title{Core DSSAT Engine API}
\description{
Functions and constants used to construct gridded DSSAT runs, select treatments,
execute experiment or sequence batches, parse DSSAT output files, and assemble
language-neutral result tables. See the package README for full workflows and
argument examples.
}
\details{
The package exposes matching R and Python entry points. Treatment selection is
normalized before batch construction; experiment batches run in DSSAT mode B
and sequence batches in mode Q. Weather extension requires a complete,
duplicate-free reference year inside the requested interval and writes through
an atomic replacement. Missing DSSAT numeric sentinels are returned as missing
values; invalid calendar dates and failed or empty runs are reported explicitly.
}
\value{
Grid helpers return spatial point objects; parsers return data frames; directory
readers return named lists of data frames. Writers and run helpers return their
created path or result table and signal invalid input or execution failure.
}
\examples{
yyddd_to_date(c(23001, 2023365, -99))
normalize_treatment_list(c(1, 3, 3))
}
