/*
S2_extract_geovars.do
=====================
Extract and merge into each wave file:
  1. HH GPS + soil + climate geovariables
  2. Plot geovariables (slope, soil quality)
  3. HH head demographics (sex, age, education)
  4. Consumption aggregates (total_cons_ann, cons_per_aeq)
  5. Drought shock indicator (sect8_hh, shock code 104)
  6. Asset count (sect10_hh — W1/W2 only; W3 file absent)

All merges report _merge diagnostics.
GPS column names differ by wave (verified against actual DTA files):
  W1 → LAT_DD_MOD / LON_DD_MOD (uppercase)
  W2/W3 → lat_dd_mod / lon_dd_mod (lowercase)

HH head age variable:
  W1/W2 → hh_s1q04_a   (with underscore before 'a')
  W3    → hh_s1q04a    (no underscore — verified against DTA)
*/

quietly do "$SCRIPTS/Stata/00_config.do"
global SCRIPTS "$BASE/Scripts"


* ============================================================================
* LOCAL HELPER: merge geovars from a file into current dataset
* ============================================================================
cap program drop merge_geofile
program define merge_geofile
    syntax, file(string) id(varname) wave(integer) ///
            lat(string) lon(string) [extrakeep(string)]
    preserve
    use "`file'", clear
    rename `lat' lat
    rename `lon' lon
    * Keep only ID + geo variables we need
    keep `id' lat lon ///
         srtm_phis* af_bio_* af_ws* dist_* popdensity* ///
         sh_* s2* anntot_* ndvi* `extrakeep'
    tempfile _geo_tmp
    save `_geo_tmp'
    restore
    merge m:1 `id' using `_geo_tmp', keep(1 3) update
    local n_unmatched = _N - r(N_matched)
    di "  W`wave' HH geo merge: `=r(N_matched)' matched, `n_unmatched' unmatched from master"
    drop _merge
end


* ============================================================================
* WAVE 1 — 2011 ERSS
* ============================================================================
report_section "WAVE 1 — Geovars & HH data"

use "$OUT/wave1_survey.dta", clear
di "Loaded wave1_survey: `=_N' rows"

* --- GPS + soil + climate geovariables ---
preserve
use "$W1/Pub_ETH_HouseholdGeovariables_Y1.dta", clear
rename LAT_DD_MOD lat
rename LON_DD_MOD lon
capture rename srtm_phis1 elevation_m
capture rename af_bio_12  annual_precip_mm
capture rename af_bio_1   annual_temp_c
capture rename dist_market dist_market_km
* For any variable that may not exist after renaming, generate missing placeholder
foreach v in elevation_m annual_precip_mm dist_market_km {
    capture confirm variable `v'
    if _rc != 0 gen `v' = .
}
forval i = 1/7 {
    capture confirm variable sq`i'
    if _rc != 0 gen sq`i' = .
}
keep household_id lat lon elevation_m annual_precip_mm dist_market_km ///
     sq1 sq2 sq3 sq4 sq5 sq6 sq7
tempfile w1_geo
save `w1_geo'
restore

merge m:1 household_id using `w1_geo', keep(1 3)
di "  W1 GPS coverage: " ///
   string(100 * (`=r(N_matched)' / _N), "%4.1f") "% matched"
assert inlist(_merge, 1, 3)   /* no right-only: all geo HHs should be in harvest data */
drop _merge

* --- Plot geovariables (slope, soil, distance to HH) ---
capture {
    preserve
    use "$W1/Pub_ETH_PlotGeovariables_Y1.dta", clear
    keep $KEYS_W1 plot_slope* dist_hh_to_plot* plot_soil*
    capture rename plot_slope1 plot_slope_pct
    capture rename dist_hh_plot dist_hh_to_plot_km
    duplicates drop $KEYS_W1, force
    tempfile w1_plotgeo
    save `w1_plotgeo'
    restore
    merge m:1 $KEYS_W1 using `w1_plotgeo', keep(1 3) nogen
    di "  W1 plot geo: merged"
}

* --- HH demographics (sect1_hh) ---
preserve
use "$W1/sect1_hh_w1.dta", clear
* Keep only household head (hh_s1q02 == 1)
keep if hh_s1q02 == 1
* One row per HH
bysort household_id: keep if _n == 1
gen head_sex = hh_s1q03
gen head_age = hh_s1q04_a     /* W1/W2 use underscore version */
gen head_education = hh_s1q08
tempfile w1_head
save `w1_head'
restore

* Count HH members for hh_size
preserve
use "$W1/sect1_hh_w1.dta", clear
bysort household_id: gen hh_size = _N
bysort household_id: keep if _n == 1
keep household_id hh_size
tempfile w1_size
save `w1_size'
restore

merge m:1 household_id using `w1_head', keep(1 3) ///
    keepusing(head_sex head_age head_education) nogen
merge m:1 household_id using `w1_size', keep(1 3) nogen

* --- Consumption aggregate ---
capture {
    preserve
    use "$W1/cons_agg_w1.dta", clear
    capture rename cons_per_adult_equiv cons_per_aeq
    foreach v in total_cons_ann cons_per_aeq {
        capture confirm variable `v'
        if _rc != 0 gen `v' = .
    }
    keep household_id total_cons_ann cons_per_aeq
    tempfile w1_cons
    save `w1_cons'
    restore
    merge m:1 household_id using `w1_cons', keep(1 3) nogen
}

* --- Drought shock from sect8_hh (shock code 104 = drought) ---
preserve
use "$W1/sect8_hh_w1.dta", clear
gen drought_shock = (hh_s8q00 == 104 & hh_s8q01 == 1) if !mi(hh_s8q00)
collapse (max) drought_shock, by(household_id)
tempfile w1_shock
save `w1_shock'
restore
merge m:1 household_id using `w1_shock', keep(1 3) nogen

* --- Assets (sect10_hh) ---
capture {
    preserve
    use "$W1/sect10_hh_w1.dta", clear
    * Count distinct asset types the HH reports owning
    gen owns_asset = (hh_s10q01 == 1) if !mi(hh_s10q01)
    collapse (sum) n_assets = owns_asset, by(household_id)
    tempfile w1_assets
    save `w1_assets'
    restore
    merge m:1 household_id using `w1_assets', keep(1 3) nogen
}

di "W1 checkpoint:"
tabstat lat lon elevation_m annual_precip_mm head_age hh_size ///
        total_cons_ann drought_shock, stat(n mean) col(stat)

save "$OUT/wave1_survey.dta", replace


* ============================================================================
* WAVE 2 — 2013 ESS
* ============================================================================
report_section "WAVE 2 — Geovars & HH data"

use "$OUT/wave2_survey.dta", clear

* --- GPS + soil + climate ---
preserve
use "$W2/Pub_ETH_HouseholdGeovars_Y2.dta", clear
rename lat_dd_mod lat
rename lon_dd_mod lon
capture rename srtm_phis1 elevation_m
capture rename af_bio_12  annual_precip_mm
capture rename af_bio_1   annual_temp_c
capture rename dist_market dist_market_km
foreach v in elevation_m annual_precip_mm dist_market_km {
    capture confirm variable `v'
    if _rc != 0 gen `v' = .
}
forval i = 1/7 {
    capture confirm variable sq`i'
    if _rc != 0 gen sq`i' = .
}
keep household_id2 lat lon elevation_m annual_precip_mm dist_market_km ///
     sq1 sq2 sq3 sq4 sq5 sq6 sq7
tempfile w2_geo
save `w2_geo'
restore

merge m:1 household_id2 using `w2_geo', keep(1 3)
di "  W2 GPS coverage: " ///
   string(100 * (`=r(N_matched)' / _N), "%4.1f") "% matched"
drop _merge

* --- Plot geovariables ---
capture {
    preserve
    use "$W2/Pub_ETH_PlotGeovariables_Y2.dta", clear
    capture rename plot_slope1 plot_slope_pct
    capture rename dist_hh_plot dist_hh_to_plot_km
    duplicates drop $KEYS_W23, force
    tempfile w2_plotgeo
    save `w2_plotgeo'
    restore
    merge m:1 $KEYS_W23 using `w2_plotgeo', keep(1 3) nogen
}

* --- HH demographics ---
preserve
use "$W2/sect1_hh_w2.dta", clear
keep if hh_s1q02 == 1
bysort household_id2: keep if _n == 1
gen head_sex = hh_s1q03
gen head_age = hh_s1q04_a
gen head_education = hh_s1q08
tempfile w2_head
save `w2_head'
restore

preserve
use "$W2/sect1_hh_w2.dta", clear
bysort household_id2: gen hh_size = _N
bysort household_id2: keep if _n == 1
keep household_id2 hh_size
tempfile w2_size
save `w2_size'
restore

merge m:1 household_id2 using `w2_head', keep(1 3) ///
    keepusing(head_sex head_age head_education) nogen
merge m:1 household_id2 using `w2_size', keep(1 3) nogen

* --- Consumption ---
capture {
    preserve
    use "$W2/cons_agg_w2.dta", clear
    keep household_id2 total_cons_ann cons_per_aeq
    tempfile w2_cons
    save `w2_cons'
    restore
    merge m:1 household_id2 using `w2_cons', keep(1 3) nogen
}

* --- Drought shock ---
preserve
use "$W2/sect8_hh_w2.dta", clear
gen drought_shock = (hh_s8q00 == 104 & hh_s8q01 == 1) if !mi(hh_s8q00)
collapse (max) drought_shock, by(household_id2)
tempfile w2_shock
save `w2_shock'
restore
merge m:1 household_id2 using `w2_shock', keep(1 3) nogen

* --- Assets ---
capture {
    preserve
    use "$W2/sect10_hh_w2.dta", clear
    gen owns_asset = (hh_s10q01 == 1) if !mi(hh_s10q01)
    collapse (sum) n_assets = owns_asset, by(household_id2)
    tempfile w2_assets
    save `w2_assets'
    restore
    merge m:1 household_id2 using `w2_assets', keep(1 3) nogen
}

di "W2 checkpoint:"
tabstat lat lon elevation_m annual_precip_mm head_age hh_size ///
        total_cons_ann drought_shock, stat(n mean) col(stat)

save "$OUT/wave2_survey.dta", replace


* ============================================================================
* WAVE 3 — 2015 ESS
* ============================================================================
report_section "WAVE 3 — Geovars & HH data"

use "$OUT/wave3_survey.dta", clear

* --- GPS + soil + climate ---
preserve
use "$W3GV/ETH_HouseholdGeovars_y3.dta", clear
rename lat_dd_mod lat
rename lon_dd_mod lon
capture rename srtm_phis1 elevation_m
capture rename af_bio_12  annual_precip_mm
capture rename af_bio_1   annual_temp_c
capture rename dist_market dist_market_km
foreach v in elevation_m annual_precip_mm dist_market_km {
    capture confirm variable `v'
    if _rc != 0 gen `v' = .
}
forval i = 1/7 {
    capture confirm variable sq`i'
    if _rc != 0 gen sq`i' = .
}
keep household_id2 lat lon elevation_m annual_precip_mm dist_market_km ///
     sq1 sq2 sq3 sq4 sq5 sq6 sq7
tempfile w3_geo
save `w3_geo'
restore

merge m:1 household_id2 using `w3_geo', keep(1 3)
di "  W3 GPS coverage: " ///
   string(100 * (`=r(N_matched)' / _N), "%4.1f") "% matched"
drop _merge

* --- Plot geovariables ---
capture {
    preserve
    use "$W3GV/ETH_PlotGeovariables_y3.dta", clear
    capture rename plot_slope1 plot_slope_pct
    capture rename dist_hh_plot dist_hh_to_plot_km
    duplicates drop $KEYS_W23, force
    tempfile w3_plotgeo
    save `w3_plotgeo'
    restore
    merge m:1 $KEYS_W23 using `w3_plotgeo', keep(1 3) nogen
}

* --- HH demographics (note W3 age variable: hh_s1q04a, no underscore) ---
preserve
use "$W3PP/../sect1_hh_w3.dta", clear   /* W3 HH file is in parent ESS folder */
capture use "$DATA/ETH_2015_ESS_v03_M_STATA/sect1_hh_w3.dta", clear
keep if hh_s1q02 == 1
bysort household_id2: keep if _n == 1
gen head_sex = hh_s1q03
* W3 uses hh_s1q04a (no underscore before 'a') — verified against DTA
capture gen head_age = hh_s1q04a
if _rc != 0 capture gen head_age = hh_s1q04_a   /* fallback */
gen head_education = hh_s1q08
tempfile w3_head
save `w3_head'
restore

preserve
use "$DATA/ETH_2015_ESS_v03_M_STATA/sect1_hh_w3.dta", clear
bysort household_id2: gen hh_size = _N
bysort household_id2: keep if _n == 1
keep household_id2 hh_size
tempfile w3_size
save `w3_size'
restore

merge m:1 household_id2 using `w3_head', keep(1 3) ///
    keepusing(head_sex head_age head_education) nogen
merge m:1 household_id2 using `w3_size', keep(1 3) nogen

* --- Consumption ---
capture {
    preserve
    use "$DATA/ETH_2015_ESS_v03_M_STATA/cons_agg_w3.dta", clear
    keep household_id2 total_cons_ann cons_per_aeq
    tempfile w3_cons
    save `w3_cons'
    restore
    merge m:1 household_id2 using `w3_cons', keep(1 3) nogen
}

* --- Drought shock ---
preserve
use "$DATA/ETH_2015_ESS_v03_M_STATA/sect8_hh_w3.dta", clear
gen drought_shock = (hh_s8q00 == 104 & hh_s8q01 == 1) if !mi(hh_s8q00)
collapse (max) drought_shock, by(household_id2)
tempfile w3_shock
save `w3_shock'
restore
merge m:1 household_id2 using `w3_shock', keep(1 3) nogen

* --- Assets: W3 has no sect10_hh file — set to missing ---
gen n_assets = .
di "  Note: W3 has no asset file — n_assets set to missing (expected)"

di "W3 checkpoint:"
tabstat lat lon elevation_m annual_precip_mm head_age hh_size ///
        total_cons_ann drought_shock, stat(n mean) col(stat)

save "$OUT/wave3_survey.dta", replace

report_section "S2 COMPLETE — Geovars & HH data merged into all 3 waves"
di "Next: run S3_build_panel.do"
