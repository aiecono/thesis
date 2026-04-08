/*
run_all.do
==========
Master do-file — runs the complete Stata pipeline S1 through S4.
Execute this file from Stata after setting SCRIPTS below.

Usage:
  In Stata command line:  do "/path/to/run_all.do"
  Or open in do-file editor and click Run.

Each script is self-contained and can also be run individually.
A log file is saved to $OUT/stata_pipeline.log.
*/

* ---------------------------------------------------------------------------
* SET THIS PATH before running
* ---------------------------------------------------------------------------
global SCRIPTS "/Users/raphaelkollegger/Desktop/Master Thesis/Scripts"
global BASE    "/Users/raphaelkollegger/Desktop/Master Thesis"

* ---------------------------------------------------------------------------
* Initialize
* ---------------------------------------------------------------------------
clear all
set more off
set type double

quietly do "$SCRIPTS/Stata/00_config.do"

cap mkdir "$OUT"

log using "$OUT/stata_pipeline.log", replace text

di "============================================================"
di "  ETHIOPIA IRRIGATION DID PIPELINE — STATA IMPLEMENTATION"
di "  " c(current_date) " " c(current_time)
di "============================================================"

* ---------------------------------------------------------------------------
* S1 — Survey extraction
* ---------------------------------------------------------------------------
di ""
di ">>> Running S1_extract_survey.do"
do "$SCRIPTS/Stata/S1_extract_survey.do"

* ---------------------------------------------------------------------------
* S2 — Geovariables & HH data
* ---------------------------------------------------------------------------
di ""
di ">>> Running S2_extract_geovars.do"
do "$SCRIPTS/Stata/S2_extract_geovars.do"

* ---------------------------------------------------------------------------
* S3 — Panel construction
* ---------------------------------------------------------------------------
di ""
di ">>> Running S3_build_panel.do"
do "$SCRIPTS/Stata/S3_build_panel.do"

* ---------------------------------------------------------------------------
* S4 — Area rescue & GPS validation
* ---------------------------------------------------------------------------
di ""
di ">>> Running S4_area_and_gps.do"
do "$SCRIPTS/Stata/S4_area_and_gps.do"

* ---------------------------------------------------------------------------
* Done
* ---------------------------------------------------------------------------
di ""
di "============================================================"
di "  ALL STEPS COMPLETE"
di "  Output: $OUT/panel_geocoded.dta"
di "============================================================"

log close
