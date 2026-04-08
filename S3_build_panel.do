/*
S3_build_panel.do
=================
Stack all three waves into a long-format panel.

Steps:
  1. Append W1 + W2 + W3
  2. Enforce the Wave 1 baseline anchor:
       Keep only W2/W3 households whose household_id appears in W1.
       W2/W3 oversampled new urban households not in the W1 rural panel.
       This step purges those additions to maintain a balanced rural panel.
  3. Filter to staple cereals (Maize, Teff, Sorghum, Wheat, Barley, Millet)
  4. Standardize household IDs (string, zero-padded)
  5. Construct household_id_merge (unified bridge for GPS merge)
  6. Generate unique_plot_id for fixed effects

Merge diagnostics after every join.
_merge == 2 observations are dropped throughout
(i.e., observations that exist in the right file but not in the harvest base).

Output: $OUT/panel_stacked.dta
*/

quietly do "$SCRIPTS/Stata/00_config.do"
global SCRIPTS "$BASE/Scripts"


* ============================================================================
* 1. APPEND WAVES
* ============================================================================
report_section "Stacking waves"

use "$OUT/wave1_survey.dta", clear
append using "$OUT/wave2_survey.dta"
append using "$OUT/wave3_survey.dta"

di "Appended panel: `=_N' rows  |  Waves: " _col(35)
tab wave


* ============================================================================
* 2. STANDARDIZE HOUSEHOLD IDs AS STRINGS (prevents scientific notation)
* ============================================================================
* Convert numeric IDs to zero-padded strings before any join or filter.
* Stata's %14.0f format forces 14-digit output, eliminating 1.23e+13 issues.

* W1: household_id
capture confirm string variable household_id
if _rc == 0 {
    gen hh_id_str_w1 = household_id if wave == 1
}
else {
    gen str20 hh_id_str_w1 = ""
    replace hh_id_str_w1 = string(household_id, "%14.0f") if wave == 1
}
replace hh_id_str_w1 = strtrim(hh_id_str_w1)

* W2/W3: household_id2
capture confirm string variable household_id2
if _rc == 0 {
    gen hh_id_str_w23 = household_id2 if wave > 1
}
else {
    gen str20 hh_id_str_w23 = ""
    replace hh_id_str_w23 = string(household_id2, "%18.0f") if wave > 1
}
replace hh_id_str_w23 = strtrim(hh_id_str_w23)

* Unified bridge ID for GPS merge (used in S4)
gen str20 household_id_merge = hh_id_str_w1  if wave == 1
replace   household_id_merge = hh_id_str_w23 if wave > 1


* ============================================================================
* 3. WAVE 1 BASELINE ANCHOR
* ============================================================================
* The W1 baseline set consists of original rural households from 2011.
* W2/W3 added new urban households; we keep only observations that match
* the W1 household_id to maintain a clean panel of original respondents.

report_section "Wave 1 Baseline Anchor"

* Extract the unique set of W1 household IDs
preserve
keep if wave == 1
keep household_id
duplicates drop
rename household_id w1_hh_anchor
tempfile anchor
save `anchor'
restore

* Match W2/W3 rows against W1 anchor using the legacy household_id column
di "Before anchor: `=_N' rows"
count if wave == 1
di "  Wave 1: `r(N)' rows (kept in full)"

* Merge anchor
gen _in_w1 = (wave == 1)   /* W1 always kept */
preserve
use `anchor', clear
rename w1_hh_anchor household_id
gen _anchor_flag = 1
tempfile anchor_flag
save `anchor_flag'
restore

merge m:1 household_id using `anchor_flag', keep(1 3) nogen
replace _in_w1 = 1 if _anchor_flag == 1
drop _anchor_flag

* Report match rates before dropping
forval w = 2/3 {
    count if wave == `w'
    local n_wave = r(N)
    count if wave == `w' & _in_w1 == 1
    local n_match = r(N)
    di "  W`w': `n_match' / `n_wave' rows matched anchor (" ///
       string(100*`n_match'/`n_wave', "%4.1f") "%)"
    if `n_match' / `n_wave' < 0.90 {
        di "  WARNING: Match rate < 90% — expected for urban expansion " ///
           "oversampling but verify ID alignment."
    }
}

* Drop non-matching W2/W3 rows
keep if _in_w1 == 1
drop _in_w1

di "After anchor: `=_N' rows"
tab wave


* ============================================================================
* 4. FILTER TO STAPLE CEREALS
* ============================================================================
report_section "Filtering to staple cereals"

di "Before filter: `=_N' rows"

* Crop names come from value labels decoded in S1. Clean the string.
replace crop_name = strtrim(stritrim(crop_name))

* Filter: keep only the 6 staple cereals
keep if inlist(crop_name, "Maize", "Teff", "Sorghum", "Wheat", "Barley", "Millet")

di "After staple filter: `=_N' rows"
tab crop_name wave, missing


* ============================================================================
* 5. ADMINISTRATIVE ID STANDARDIZATION FOR AREA RESCUE
* ============================================================================
* The area rescue in S4 merges on (wave, region, zone, woreda, area_unit_code).
* These must be consistent strings without trailing .0 artifacts.
foreach v in region zone woreda area_unit_code {
    capture tostring `v', replace force
    * Remove .0 suffix from float-converted integers
    replace `v' = regexr(`v', "\.0$", "")
    replace `v' = strtrim(`v')
}


* ============================================================================
* 6. UNIQUE PLOT ID FOR FIXED EFFECTS
* ============================================================================
* Concatenate household_id + parcel_id + field_id.
* Use holder_id too when available to handle multiple holders per HH.
gen str60 unique_plot_id = hh_id_str_w1 + "_" + ///
    string(holder_id, "%6.0f") + "_" + ///
    string(parcel_id, "%4.0f") + "_" + ///
    string(field_id,  "%4.0f")

replace unique_plot_id = strtrim(stritrim(unique_plot_id))

qui levelsof unique_plot_id, local(plots)
local n_plots : word count `plots'
di "  Total unique plots: `n_plots'"

* Plots appearing in more than one wave
bysort unique_plot_id: gen _n_waves = (wave != wave[_n-1]) + (wave != wave[_n+1])
capture drop _n_waves
tempvar nwave
bysort unique_plot_id (wave): gen `nwave' = wave[_N] != wave[1]
qui count if `nwave'
di "  Plots in >1 wave: " r(N) " (" string(100*r(N)/_N, "%4.1f") "%)"


* ============================================================================
* 7. CHECKPOINT
* ============================================================================
sort unique_plot_id year

report_section "Panel checkpoint"
tabstat harvest_kg irrigation_ipt total_fertilizer_kg plot_ha ///
        lat lon elevation_m annual_precip_mm ///
        head_age head_sex hh_size total_cons_ann drought_shock, ///
    stat(n mean sd min max) col(stat)

di ""
di "Balance check: irrigated vs rainfed"
di "  (irrigated plots expected in structurally drier areas — lower precip, higher cons)"
tabstat harvest_kg total_fertilizer_kg plot_ha head_age hh_size ///
        total_cons_ann elevation_m annual_precip_mm ///
    if irrigation_ipt == 1, stat(mean) col(stat)
tabstat harvest_kg total_fertilizer_kg plot_ha head_age hh_size ///
        total_cons_ann elevation_m annual_precip_mm ///
    if irrigation_ipt == 0, stat(mean) col(stat)


* ============================================================================
* 8. SAVE
* ============================================================================
compress
save "$OUT/panel_stacked.dta", replace
di ""
report_section "S3 COMPLETE — panel_stacked.dta saved (`=_N' rows)"
di "Next: run S4_area_and_gps.do"
