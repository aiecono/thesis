/*
S4_area_and_gps.do
==================
Rescue missing plot areas via the World Bank local-unit conversion files,
then validate GPS coverage.

Area rescue logic:
  - Merge conversion file on (wave, region, zone, woreda, area_unit_code)
  - Compute imputed_ha = (plot_area_raw × sqm_per_unit) / 10,000
  - Fill missing plot_ha with imputed_ha where available
  - Conversion file covers unit codes 3–6 only; codes 8–11 remain missing
  - Report per-wave coverage before and after rescue

GPS validation:
  - GPS was already merged from geovariable files in S2
  - Here we validate coverage per wave and flag rows without GPS
    (these will have missing WRSI after the S6 merge)

Output: $OUT/panel_geocoded.dta

NOTE: No intensity ratios are computed here. yield_kg_ha, fert_kg_ha,
and labor_days_ha are computed in S5 (Python) after winsorization.
*/

quietly do "$SCRIPTS/Stata/00_config.do"
global SCRIPTS "$BASE/Scripts"


* ============================================================================
* 1. LOAD PANEL
* ============================================================================
use "$OUT/panel_stacked.dta", clear
di "Loaded panel_stacked: `=_N' rows  |  `=c(k)' columns"

* Count missing plot_ha before rescue
count if mi(plot_ha)
local n_miss_before = r(N)
di "plot_ha missing before rescue: `n_miss_before' (" ///
   string(100*`n_miss_before'/_N, "%4.1f") "%)"


* ============================================================================
* 2. LOAD & STANDARDIZE CONVERSION FILES
* ============================================================================
report_section "Loading WB area conversion files"

* W1 conversion
use "$W1/ET_local_area_unit_conversion.dta", clear
rename saq01 region
rename saq02 zone
rename saq03 woreda
rename local_unit area_unit_code
rename conversion sqm_per_unit
gen wave = 1
foreach v in region zone woreda area_unit_code {
    tostring `v', replace force
    replace `v' = regexr(`v', "\.0$", "")
    replace `v' = strtrim(`v')
}
keep wave region zone woreda area_unit_code sqm_per_unit
tempfile conv_w1
save `conv_w1'
qui levelsof area_unit_code, local(codes_w1)
di "W1 conversion: `=_N' rows  (unit codes: `codes_w1')"

* W2 conversion
use "$W2/ET_local_area_unit_conversion.dta", clear
rename saq01 region
rename saq02 zone
rename saq03 woreda
rename local_unit area_unit_code
rename conversion sqm_per_unit
gen wave = 2
foreach v in region zone woreda area_unit_code {
    tostring `v', replace force
    replace `v' = regexr(`v', "\.0$", "")
    replace `v' = strtrim(`v')
}
keep wave region zone woreda area_unit_code sqm_per_unit
tempfile conv_w2
save `conv_w2'

* W3 conversion
use "$W3CF/ET_local_area_unit_conversion.dta", clear
rename saq01 region
rename saq02 zone
rename saq03 woreda
rename local_unit area_unit_code
rename conversion sqm_per_unit
gen wave = 3
foreach v in region zone woreda area_unit_code {
    tostring `v', replace force
    replace `v' = regexr(`v', "\.0$", "")
    replace `v' = strtrim(`v')
}
keep wave region zone woreda area_unit_code sqm_per_unit
tempfile conv_w3
save `conv_w3'

* Stack all conversion files
use `conv_w1', clear
append using `conv_w2'
append using `conv_w3'
duplicates drop wave region zone woreda area_unit_code, force
tempfile conv_all
save `conv_all'
di "Combined conversion file: `=_N' rows"


* ============================================================================
* 3. MERGE CONVERSION FACTORS
* ============================================================================
use "$OUT/panel_stacked.dta", clear   /* reload clean copy */

merge m:1 wave region zone woreda area_unit_code using `conv_all', keep(1 3)
di "Conversion merge: matched `=r(N_matched)' rows"
drop _merge


* ============================================================================
* 4. AREA RESCUE
* ============================================================================
report_section "Area rescue"

gen _imputed_ha = (plot_area_raw * sqm_per_unit) / 10000

gen _rescued = (mi(plot_ha) & !mi(_imputed_ha))
replace plot_ha = _imputed_ha if mi(plot_ha) & !mi(_imputed_ha)

count if _rescued
di "Rescued `r(N)' plot areas from WB conversion file"
count if mi(plot_ha)
di "Still missing after rescue: `r(N)'"
di "Note: Codes 8, 9, 10, 11 (non-standard local units) remain unrescuable."

* Per-wave breakdown
di ""
di "Per-wave area coverage after rescue:"
di "  Wave   Total   Rescued   Missing   Miss%"
di "  " _dup(46) "-"
forval w = 1/3 {
    count if wave == `w'
    local n_total = r(N)
    count if wave == `w' & _rescued
    local n_rescued = r(N)
    count if wave == `w' & mi(plot_ha)
    local n_miss = r(N)
    local pct = 100 * `n_miss' / `n_total'
    di "  `w'      `n_total'   `n_rescued'       `n_miss'       " ///
       string(`pct', "%4.1f") "%"
    if `pct' > 10 {
        di "  WARNING: W`w' has >`pct'% missing plot_ha — " ///
           "yield intensity will be NaN for these rows."
    }
}

drop _imputed_ha _rescued sqm_per_unit


* ============================================================================
* 5. GPS COVERAGE VALIDATION
* ============================================================================
report_section "GPS coverage validation"

count if !mi(lat)
di "Overall GPS coverage: " string(100*r(N)/_N, "%4.1f") "%"

di ""
di "Per-wave GPS coverage:"
di "  Wave   With GPS   Total   Coverage%   Missing→WRSI NaN"
di "  " _dup(54) "-"
forval w = 1/3 {
    count if wave == `w'
    local n_total = r(N)
    count if wave == `w' & !mi(lat)
    local n_gps = r(N)
    local n_miss = `n_total' - `n_gps'
    local pct = 100 * `n_gps' / `n_total'
    di "  `w'      `n_gps'   `n_total'   " ///
       string(`pct', "%4.1f") "%   `n_miss'"
    if `pct' < 90 {
        di "  WARNING: W`w' GPS < 90% — check ID alignment in S2."
    }
}


* ============================================================================
* 6. CHECKPOINT & SAVE
* ============================================================================
report_section "Geocoded panel checkpoint"
tabstat plot_ha lat lon harvest_kg irrigation_ipt total_fertilizer_kg, ///
    stat(n mean sd) col(stat)

compress
save "$OUT/panel_geocoded.dta", replace

di ""
report_section "S4 COMPLETE — panel_geocoded.dta saved (`=_N' rows)"
di ""
di "Stata pipeline S1–S4 complete."
di "Cross-validate against Python output:"
di "  Python: Data/processed/panel/panel_analysis.parquet"
di "  Stata:  Data/processed/stata/panel_geocoded.dta"
di ""
di "Key comparison variables:"
di "  - irrigation_ipt: rate should be ~2% overall"
di "  - harvest_kg: mean ~190–220 kg pre-winsorization"
di "  - total_fertilizer_kg: ~57% missing"
di "  - GPS coverage: ~99.9%"
