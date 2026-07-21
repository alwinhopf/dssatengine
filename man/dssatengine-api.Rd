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
and sequence batches in mode Q.
}
