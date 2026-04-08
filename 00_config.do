/*
00_config.do
============
Shared global macros for the Stata pipeline (S1–S4).
Run this at the start of every do-file via: do "00_config.do"

All wave-specific variable names are defined here so that discrepancies
are caught in one place, not scattered across four scripts.
*/

clear all
set more off
set type double          // prevent float precision loss in ID variables

* ---------------------------------------------------------------------------
* BASE PATHS
* ---------------------------------------------------------------------------
global BASE  "/Users/raphaelkollegger/Desktop/Master Thesis"
global DATA  "$BASE/Data"
global OUT   "$DATA/processed/stata"

* Raw wave directories
global W1   "$DATA/ETH_2011_ERSS_v02_M_Stata8"
global W2   "$DATA/ETH_2013_ESS_v03_M_STATA"
global W3PP "$DATA/ETH_2015_ESS_v03_M_STATA/Post-Planting"
global W3PH "$DATA/ETH_2015_ESS_v03_M_STATA/Post-Harvest"
global W3GV "$DATA/ETH_2015_ESS_v03_M_STATA/Geovariables"
global W3CF "$DATA/ETH_2015_ESS_v03_M_STATA/Land Area Conversion Factor"

* ---------------------------------------------------------------------------
* MERGE KEYS
* ---------------------------------------------------------------------------
* W1 plot-level key (no household_id2)
global KEYS_W1  "household_id holder_id parcel_id field_id"
* W2/W3 plot-level key (household_id2 is the primary ID)
global KEYS_W23 "household_id2 holder_id parcel_id field_id"
* W1 crop-level key (adds crop_code)
global CROP_W1  "household_id holder_id parcel_id field_id crop_code"
* W2/W3 crop-level key
global CROP_W23 "household_id2 holder_id parcel_id field_id crop_code"

* ---------------------------------------------------------------------------
* WAVE-SPECIFIC FERTILIZER VARIABLE NAMES (verified against actual DTA files)
* ---------------------------------------------------------------------------
* UREA (kg applied): W1=pp_s3q16_c, W2=pp_s3q16_a, W3=pp_s3q16
* DAP  (kg applied): W1=pp_s3q19_a, W2=pp_s3q19_a, W3=pp_s3q19
* NPS  (kg applied): W3 only = pp_s3q20a_2

* ---------------------------------------------------------------------------
* WAVE-SPECIFIC AREA VARIABLE NAMES
* ---------------------------------------------------------------------------
* Self-reported area quantity: pp_s3q02_a  (all waves)
* Self-reported area unit:     pp_s3q02_c  (all waves)
* GPS area (sqm):              W1=pp_s3q05_c,  W2/W3=pp_s3q05_a

* ---------------------------------------------------------------------------
* HARVEST VARIABLE NAMES
* ---------------------------------------------------------------------------
* W1: ph_s9q12_a (kg) + ph_s9q12_b (grams) → farmer-reported total harvest
* W2/W3: ph_s9q05 → farmer-reported total quantity harvested
* Harvest months: W1=ph_s9q13_a/_b, W2/W3=ph_s9q07_a/_b

* ---------------------------------------------------------------------------
* STAPLE CEREALS (crop codes verified from crop_code_map)
* ---------------------------------------------------------------------------
* Maize=2, Teff=7, Sorghum=6, Wheat=8, Barley=1, Millet=3
global STAPLE_CODES "1 2 3 6 7 8"

* ---------------------------------------------------------------------------
* HELPER MACRO: display a summary header
* ---------------------------------------------------------------------------
cap program drop report_section
program define report_section
    args title
    di ""
    di _dup(70) "="
    di "  `title'"
    di _dup(70) "="
end
