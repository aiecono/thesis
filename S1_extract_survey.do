/*
S1_extract_survey.do
====================
Extract and harmonize plot-level survey data from raw .dta files
for all 3 waves. Produces one .dta per wave with consistent column names.

No filtering, winsorization, or derived variables — pure extraction.

Inputs:  sect3_pp, sect4_pp, sect9_ph, sect10_ph (all waves)
Outputs: $OUT/wave1_survey.dta
         $OUT/wave2_survey.dta
         $OUT/wave3_survey.dta

Merge diagnostics are reported after every merge.
_merge == 2 (right-only) is always dropped: we start from harvest,
so unmatched planting/plot observations are not our unit of analysis.
*/

quietly do "$SCRIPTS/Stata/00_config.do"
global SCRIPTS "$BASE/Scripts"

* ============================================================================
* HELPER PROGRAMS
* ============================================================================

/*  nan_aware_sum  <newvar> = <v1> <v2> ... <vN>
    Equivalent to Python's .sum(axis=1, min_count=1):
    If ALL components are missing → newvar = .
    Otherwise → sum of non-missing components.
    Usage: nan_aware_sum labor_total = hired_men hired_women hired_child
*/
cap program drop nan_aware_sum
program define nan_aware_sum
    * Usage: nan_aware_sum newvar, inputs(var1 var2 var3)
    * Equivalent to pandas .sum(axis=1, min_count=1):
    *   all missing  → newvar = .
    *   otherwise    → sum of non-missing components
    syntax newvarname, inputs(varlist)
    * NOTE: `varlist' holds the new variable name; `inputs' is a standard option
    local nvars : word count `inputs'
    tempvar running_sum nmiss
    gen double `running_sum' = 0
    gen double `nmiss'       = 0
    foreach v of local inputs {
        replace `running_sum' = `running_sum' + cond(mi(`v'), 0, `v')
        replace `nmiss'       = `nmiss' + mi(`v')
    }
    gen double `varlist' = `running_sum'
    replace `varlist' = . if `nmiss' == `nvars'
end


/*  hh_member_labor_days  <newvar>  <stub>
    Compute household-member labor days from wide-format columns:
    <stub>_a (member id), <stub>_b (weeks), <stub>_c (days/week),
    <stub>_d (hours/day, default 8 if missing).
    Groups of 4 alphabetical letters, supports up to 8 members (32 cols → a-af).
*/
cap program drop hh_member_labor_days
program define hh_member_labor_days
    syntax newvarname, stub(string)
    * NOTE: Stata stores the parsed new variable name in `varlist', not `newvarname'
    gen `varlist' = 0
    local letters "a b c d e f g h i j k l m n o p q r s t u v w x y z aa ab ac ad ae af"
    local nlet : word count `letters'
    local member = 1
    local col_i  = 1  /* index into letter list; each member uses 4 cols */
    while `col_i' <= `nlet' - 3 {
        local l1 : word `col_i'       of `letters'  /* member id   */
        local l2 : word `=`col_i'+1'  of `letters'  /* weeks       */
        local l3 : word `=`col_i'+2'  of `letters'  /* days/week   */
        local l4 : word `=`col_i'+3'  of `letters'  /* hours/day   */
        capture confirm variable `stub'_`l2'
        if _rc != 0 {
            * No more member columns — stop
            continue, break
        }
        capture confirm variable `stub'_`l3'
        if _rc != 0 continue, break
        tempvar hrs_adj contrib
        * Default hours = 8 if not recorded
        capture confirm variable `stub'_`l4'
        if _rc == 0 {
            gen `hrs_adj' = cond(mi(`stub'_`l4'), 8, `stub'_`l4')
        }
        else {
            gen `hrs_adj' = 8
        }
        gen `contrib' = `stub'_`l2' * `stub'_`l3' * (`hrs_adj' / 8)
        replace `varlist' = `varlist' + cond(mi(`contrib'), 0, `contrib')
        drop `hrs_adj' `contrib'
        local col_i = `col_i' + 4
        local ++member
    }
    label var `varlist' "HH-member labor days (weeks × days/wk × hrs/8)"
end


/*  compute_hired_labor  <newvar>
    Hired labor = (N_men × days_men) + (N_women × days_women) + (N_child × days_child)
    Columns: ph_s10q01_a/_b  (men), ph_s10q01_d/_e  (women), ph_s10q01_g/_h (children)
    NaN-aware: if all three sub-totals are missing → newvar = .
*/
cap program drop compute_hired_labor
program define compute_hired_labor
    syntax newvarname, ///
        num_men(varname) day_men(varname) ///
        num_wom(varname) day_wom(varname) ///
        num_chi(varname) day_chi(varname)
    * NOTE: Stata stores the parsed new variable name in `varlist', not `newvarname'
    tempvar hired_men hired_wom hired_chi
    gen `hired_men' = `num_men' * `day_men'
    gen `hired_wom' = `num_wom' * `day_wom'
    gen `hired_chi' = `num_chi' * `day_chi'
    nan_aware_sum `varlist', inputs(`hired_men' `hired_wom' `hired_chi')
end


/*  compute_exchange_labor  <newvar>
    Exchange labor = (N_men × days) + (N_women × days) + (N_child × days)
    harvest: ph_s10q03_a/_b, _c/_d, _e/_f
    planting: pp_s3q29_a/_b, _c/_d, _e/_f
*/
cap program drop compute_exchange_labor
program define compute_exchange_labor
    syntax newvarname, ///
        num_men(varname) day_men(varname) ///
        num_wom(varname) day_wom(varname) ///
        num_chi(varname) day_chi(varname)
    * NOTE: Stata stores the parsed new variable name in `varlist', not `newvarname'
    tempvar exch_men exch_wom exch_chi
    gen `exch_men' = `num_men' * `day_men'
    gen `exch_wom' = `num_wom' * `day_wom'
    gen `exch_chi' = `num_chi' * `day_chi'
    nan_aware_sum `varlist', inputs(`exch_men' `exch_wom' `exch_chi')
end


* ============================================================================
* WAVE 1 — 2011 ERSS
* ============================================================================
report_section "WAVE 1 (2011 ERSS)"

* --- 1a. Harvest data (base: one row per plot × crop observed at harvest) ---
use "$W1/sect9_ph_w1.dta", clear
di "sect9_ph_w1: `=_N' rows"
duplicates report $CROP_W1
assert r(unique_value) == _N, rc0  /* every plot×crop should be unique */

* Harvest quantity: kg + grams (NaN-aware)
gen _harv_kg  = ph_s9q12_a
gen _harv_g   = ph_s9q12_b / 1000
gen harvest_kg = .
replace harvest_kg = cond(mi(_harv_kg), 0, _harv_kg) + ///
                     cond(mi(_harv_g),  0, _harv_g)  ///
    if !mi(_harv_kg) | !mi(_harv_g)
drop _harv_kg _harv_g

* Harvest months
rename ph_s9q13_a harvest_start_month
rename ph_s9q13_b harvest_end_month

* Partial harvest flag (1=partial, 2=complete → recode to 0/1)
gen harvest_partial = (ph_s9q07 == 1) if !mi(ph_s9q07)

* Post-harvest damage
gen crop_damaged_post      = (ph_s9q09 == 1) if !mi(ph_s9q09)
gen crop_damage_cause_post = ph_s9q10
gen crop_damage_pct_post   = ph_s9q11
gen pct_area_harvested     = .      /* not available in W1 */

* Crop name from value labels (native Stata — no float/int risk)
* crop_name may already exist as a string label in the DTA — only decode if absent
capture confirm variable crop_name
if _rc != 0 decode crop_code, gen(crop_name)
replace crop_name = strtrim(stritrim(crop_name))

keep $CROP_W1 harvest_kg harvest_start_month harvest_end_month ///
     harvest_partial crop_damaged_post crop_damage_cause_post ///
     crop_damage_pct_post pct_area_harvested crop_name

tempfile w1_harvest
save `w1_harvest'

* --- 1b. Crop planting data ---
use "$W1/sect4_pp_w1.dta", clear
di "sect4_pp_w1: `=_N' rows"
duplicates report $CROP_W1

gen plant_month      = pp_s4q12_a
gen crop_stand       = pp_s4q02
gen crop_area_share  = pp_s4q03
gen improved_seed    = (pp_s4q11 == 2) if !mi(pp_s4q11)   /* 2=improved, 1=local */
gen pesticide_use    = (pp_s4q05 == 1) if !mi(pp_s4q05)
gen herbicide_use    = (pp_s4q06 == 1) if !mi(pp_s4q06)
gen fungicide_use    = (pp_s4q07 == 1) if !mi(pp_s4q07)
gen crop_damaged_pre      = (pp_s4q08 == 1) if !mi(pp_s4q08)
gen crop_damage_cause_pre = pp_s4q09
gen crop_damage_pct_pre   = pp_s4q10
gen seed_qty_kg           = .   /* not available in W1 */

keep $CROP_W1 plant_month crop_stand crop_area_share improved_seed ///
     pesticide_use herbicide_use fungicide_use ///
     crop_damaged_pre crop_damage_cause_pre crop_damage_pct_pre seed_qty_kg

tempfile w1_crop
save `w1_crop'

* --- 1c. Plot-level data from sect3_pp ---
use "$W1/sect3_pp_w1.dta", clear
di "sect3_pp_w1: `=_N' rows"
duplicates report $KEYS_W1

* Geography (administrative codes)
gen region = saq01
gen zone   = saq02
gen woreda = saq03

* Plot area
gen plot_area_raw  = pp_s3q02_a    /* self-reported quantity     */
gen area_unit_code = pp_s3q02_c    /* local unit code            */
gen plot_area_sqm  = pp_s3q05_c    /* GPS-measured sqm (W1)      */
gen plot_ha        = pp_s3q05_c / 10000   /* GPS ha (primary for W1) */
* Fallback for GPS-missing: use raw × simple code map
* (codes 1=timad, 2=timad, 3=hectare, 4=sq.m, 5=acre, 6=gasha)
* Full rescue handled in S4 via WB conversion file
gen _fallback_ha = pp_s3q02_a / 10000 if area_unit_code == 4  /* sqm already */
replace plot_ha = _fallback_ha if mi(plot_ha) & !mi(_fallback_ha)
drop _fallback_ha
replace plot_ha = . if plot_ha > 50   /* >50 ha cannot be a smallholder field */

* Irrigation: 1=yes, 2=no → recode to 1/0
gen irrigation_ipt = (pp_s3q12 == 1) if !mi(pp_s3q12)
gen irrig_source   = pp_s3q13

* Fertilizer — verified variable names:
*   W1 UREA = pp_s3q16_c, W1 DAP = pp_s3q19_a
gen urea_kg = pp_s3q16_c
gen dap_kg  = pp_s3q19_a
* NaN-aware total: missing only if BOTH urea AND dap are missing
gen total_fertilizer_kg = 0
gen _fert_answered = 0
replace total_fertilizer_kg = total_fertilizer_kg + urea_kg if !mi(urea_kg)
replace _fert_answered = 1 if !mi(urea_kg)
replace total_fertilizer_kg = total_fertilizer_kg + dap_kg  if !mi(dap_kg)
replace _fert_answered = 1 if !mi(dap_kg)
replace total_fertilizer_kg = . if _fert_answered == 0
drop _fert_answered
gen nps_kg = .   /* NPS not available in W1 */

* Other inputs
gen manure_use     = (pp_s3q21 == 1) if !mi(pp_s3q21)
gen compost_use    = (pp_s3q23 == 1) if !mi(pp_s3q23)

* Sample weight
gen sample_weight = pw

* Planting labor (sect3_pp pp_s3q27_* and pp_s3q28_*, pp_s3q29_*)
hh_member_labor_days labor_hh_plant, stub(pp_s3q27)

compute_hired_labor labor_hired_plant, ///
    num_men(pp_s3q28_a) day_men(pp_s3q28_b) ///
    num_wom(pp_s3q28_d) day_wom(pp_s3q28_e) ///
    num_chi(pp_s3q28_g) day_chi(pp_s3q28_h)

compute_exchange_labor labor_exchange_plant, ///
    num_men(pp_s3q29_a) day_men(pp_s3q29_b) ///
    num_wom(pp_s3q29_c) day_wom(pp_s3q29_d) ///
    num_chi(pp_s3q29_e) day_chi(pp_s3q29_f)

nan_aware_sum labor_total_plant = labor_hh_plant labor_hired_plant labor_exchange_plant

keep $KEYS_W1 region zone woreda ///
     plot_area_raw area_unit_code plot_area_sqm plot_ha ///
     irrigation_ipt irrig_source ///
     urea_kg dap_kg nps_kg total_fertilizer_kg ///
     manure_use compost_use sample_weight ///
     labor_hh_plant labor_hired_plant labor_exchange_plant labor_total_plant

tempfile w1_plot
save `w1_plot'

* --- 1d. Harvest labor from sect10_ph ---
use "$W1/sect10_ph_w1.dta", clear
di "sect10_ph_w1: `=_N' rows"

compute_hired_labor labor_hired_harvest, ///
    num_men(ph_s10q01_a) day_men(ph_s10q01_b) ///
    num_wom(ph_s10q01_d) day_wom(ph_s10q01_e) ///
    num_chi(ph_s10q01_g) day_chi(ph_s10q01_h)

hh_member_labor_days labor_hh_harvest, stub(ph_s10q02)

compute_exchange_labor labor_exchange_harvest, ///
    num_men(ph_s10q03_a) day_men(ph_s10q03_b) ///
    num_wom(ph_s10q03_c) day_wom(ph_s10q03_d) ///
    num_chi(ph_s10q03_e) day_chi(ph_s10q03_f)

nan_aware_sum labor_total_harvest = labor_hired_harvest labor_hh_harvest labor_exchange_harvest

* Collapse to plot level (sect10 can have multiple rows per plot in some waves)
collapse (sum) labor_hired_harvest labor_hh_harvest labor_exchange_harvest labor_total_harvest, ///
    by($KEYS_W1)

tempfile w1_labor
save `w1_labor'

* --- 1e. Assemble Wave 1 ---
use `w1_harvest', clear
merge m:1 $CROP_W1  using `w1_crop',   keep(1 3) nogen
merge m:1 $KEYS_W1  using `w1_plot',   keep(1 3) nogen
merge m:1 $KEYS_W1  using `w1_labor',  keep(1 3) nogen

gen year = 2011
gen wave = 1
label var irrigation_ipt "Irrigated plot (1=yes, 0=no)"
label var harvest_kg      "Total harvest quantity (kg)"
label var total_fertilizer_kg "Total chemical fertilizer applied (kg)"

* Quick check
di "Wave 1 assembled: `=_N' rows"
tabstat harvest_kg irrigation_ipt total_fertilizer_kg plot_ha, ///
    stat(n mean sd) col(stat)

save "$OUT/wave1_survey.dta", replace
di "Saved: $OUT/wave1_survey.dta"


* ============================================================================
* WAVE 2 — 2013 ESS
* ============================================================================
report_section "WAVE 2 (2013 ESS)"

* --- 2a. Harvest ---
use "$W2/sect9_ph_w2.dta", clear
di "sect9_ph_w2: `=_N' rows"
duplicates report $CROP_W23

gen harvest_kg         = ph_s9q05
rename ph_s9q07_a harvest_start_month
rename ph_s9q07_b harvest_end_month
gen harvest_partial        = (ph_s9q08 == 1) if !mi(ph_s9q08)
gen crop_damaged_post      = (ph_s9q11 == 1) if !mi(ph_s9q11)
gen crop_damage_cause_post = ph_s9q12
gen crop_damage_pct_post   = ph_s9q13
gen pct_area_harvested     = ph_s9q09

* Preserve W1 legacy ID for panel linking
rename household_id household_id_w1_link    /* rename to avoid collision at append */

* crop_name may already exist as a string label in the DTA — only decode if absent
capture confirm variable crop_name
if _rc != 0 decode crop_code, gen(crop_name)
replace crop_name = strtrim(stritrim(crop_name))

keep $CROP_W23 household_id_w1_link harvest_kg harvest_start_month harvest_end_month ///
     harvest_partial crop_damaged_post crop_damage_cause_post ///
     crop_damage_pct_post pct_area_harvested crop_name

tempfile w2_harvest
save `w2_harvest'

* --- 2b. Crop planting ---
use "$W2/sect4_pp_w2.dta", clear
duplicates report $CROP_W23

gen plant_month      = pp_s4q12_a
gen crop_stand       = pp_s4q02
gen crop_area_share  = pp_s4q03
gen improved_seed    = (pp_s4q11 == 2) if !mi(pp_s4q11)
gen pesticide_use    = (pp_s4q05 == 1) if !mi(pp_s4q05)
gen herbicide_use    = (pp_s4q06 == 1) if !mi(pp_s4q06)
gen fungicide_use    = (pp_s4q07 == 1) if !mi(pp_s4q07)
gen crop_damaged_pre      = (pp_s4q08 == 1) if !mi(pp_s4q08)
gen crop_damage_cause_pre = pp_s4q09
gen crop_damage_pct_pre   = pp_s4q10
capture gen seed_qty_kg = pp_s4q11b    /* W2 has seed quantity */

keep $CROP_W23 plant_month crop_stand crop_area_share improved_seed ///
     pesticide_use herbicide_use fungicide_use ///
     crop_damaged_pre crop_damage_cause_pre crop_damage_pct_pre seed_qty_kg

tempfile w2_crop
save `w2_crop'

* --- 2c. Plot ---
use "$W2/sect3_pp_w2.dta", clear
duplicates report $KEYS_W23

gen region = saq01
gen zone   = saq02
gen woreda = saq03

gen plot_area_raw  = pp_s3q02_a
gen area_unit_code = pp_s3q02_c
gen plot_area_sqm  = pp_s3q05_a     /* GPS sqm (W2) */
* For W2, primary plot_ha comes from S4 area rescue (conversion file)
* Use simple fallback here; S4 will fill in remaining
gen plot_ha = pp_s3q05_a / 10000    /* GPS ha */
gen _fallback_ha = pp_s3q02_a / 10000 if area_unit_code == 4
replace plot_ha = _fallback_ha if mi(plot_ha) & !mi(_fallback_ha)
drop _fallback_ha
replace plot_ha = . if plot_ha > 50

gen irrigation_ipt = (pp_s3q12 == 1) if !mi(pp_s3q12)
gen irrig_source   = pp_s3q13

* W2 UREA = pp_s3q16_a, W2 DAP = pp_s3q19_a
gen urea_kg = pp_s3q16_a
gen dap_kg  = pp_s3q19_a
gen total_fertilizer_kg = 0
gen _fert_answered = 0
replace total_fertilizer_kg = total_fertilizer_kg + urea_kg if !mi(urea_kg)
replace _fert_answered = 1 if !mi(urea_kg)
replace total_fertilizer_kg = total_fertilizer_kg + dap_kg  if !mi(dap_kg)
replace _fert_answered = 1 if !mi(dap_kg)
replace total_fertilizer_kg = . if _fert_answered == 0
drop _fert_answered
gen nps_kg = .

gen manure_use  = (pp_s3q21 == 1) if !mi(pp_s3q21)
gen compost_use = (pp_s3q23 == 1) if !mi(pp_s3q23)
gen sample_weight = pw2

hh_member_labor_days labor_hh_plant, stub(pp_s3q27)
compute_hired_labor labor_hired_plant, ///
    num_men(pp_s3q28_a) day_men(pp_s3q28_b) ///
    num_wom(pp_s3q28_d) day_wom(pp_s3q28_e) ///
    num_chi(pp_s3q28_g) day_chi(pp_s3q28_h)
compute_exchange_labor labor_exchange_plant, ///
    num_men(pp_s3q29_a) day_men(pp_s3q29_b) ///
    num_wom(pp_s3q29_c) day_wom(pp_s3q29_d) ///
    num_chi(pp_s3q29_e) day_chi(pp_s3q29_f)
nan_aware_sum labor_total_plant = labor_hh_plant labor_hired_plant labor_exchange_plant

keep $KEYS_W23 region zone woreda ///
     plot_area_raw area_unit_code plot_area_sqm plot_ha ///
     irrigation_ipt irrig_source ///
     urea_kg dap_kg nps_kg total_fertilizer_kg ///
     manure_use compost_use sample_weight ///
     labor_hh_plant labor_hired_plant labor_exchange_plant labor_total_plant

tempfile w2_plot
save `w2_plot'

* --- 2d. Harvest labor ---
use "$W2/sect10_ph_w2.dta", clear
compute_hired_labor labor_hired_harvest, ///
    num_men(ph_s10q01_a) day_men(ph_s10q01_b) ///
    num_wom(ph_s10q01_d) day_wom(ph_s10q01_e) ///
    num_chi(ph_s10q01_g) day_chi(ph_s10q01_h)
hh_member_labor_days labor_hh_harvest, stub(ph_s10q02)
compute_exchange_labor labor_exchange_harvest, ///
    num_men(ph_s10q03_a) day_men(ph_s10q03_b) ///
    num_wom(ph_s10q03_c) day_wom(ph_s10q03_d) ///
    num_chi(ph_s10q03_e) day_chi(ph_s10q03_f)
nan_aware_sum labor_total_harvest = labor_hired_harvest labor_hh_harvest labor_exchange_harvest
collapse (sum) labor_hired_harvest labor_hh_harvest labor_exchange_harvest labor_total_harvest, ///
    by($KEYS_W23)
tempfile w2_labor
save `w2_labor'

* --- 2e. Assemble Wave 2 ---
use `w2_harvest', clear
merge m:1 $CROP_W23 using `w2_crop',  keep(1 3) nogen
merge m:1 $KEYS_W23 using `w2_plot',  keep(1 3) nogen
merge m:1 $KEYS_W23 using `w2_labor', keep(1 3) nogen

gen year = 2013
gen wave = 2
* Rename for panel compatibility: household_id = W1 legacy ID
rename household_id_w1_link household_id

di "Wave 2 assembled: `=_N' rows"
tabstat harvest_kg irrigation_ipt total_fertilizer_kg plot_ha, stat(n mean sd) col(stat)

save "$OUT/wave2_survey.dta", replace
di "Saved: $OUT/wave2_survey.dta"


* ============================================================================
* WAVE 3 — 2015 ESS
* ============================================================================
report_section "WAVE 3 (2015 ESS)"

* --- 3a. Harvest ---
use "$W3PH/sect9_ph_w3.dta", clear
di "sect9_ph_w3: `=_N' rows"
duplicates report $CROP_W23

gen harvest_kg             = ph_s9q05
rename ph_s9q07_a harvest_start_month
rename ph_s9q07_b harvest_end_month
gen harvest_partial        = (ph_s9q08 == 1) if !mi(ph_s9q08)
gen crop_damaged_post      = (ph_s9q11 == 1) if !mi(ph_s9q11)
gen crop_damage_cause_post = ph_s9q12
gen crop_damage_pct_post   = ph_s9q13
gen pct_area_harvested     = ph_s9q09

capture rename household_id household_id_w1_link

* crop_name may already exist as a string label in the DTA — only decode if absent
capture confirm variable crop_name
if _rc != 0 decode crop_code, gen(crop_name)
replace crop_name = strtrim(stritrim(crop_name))

keep $CROP_W23 household_id_w1_link harvest_kg harvest_start_month harvest_end_month ///
     harvest_partial crop_damaged_post crop_damage_cause_post ///
     crop_damage_pct_post pct_area_harvested crop_name

tempfile w3_harvest
save `w3_harvest'

* --- 3b. Crop planting ---
use "$W3PP/sect4_pp_w3.dta", clear
duplicates report $CROP_W23

gen plant_month     = pp_s4q12_a
gen crop_stand      = pp_s4q02
gen crop_area_share = pp_s4q03
gen improved_seed   = (pp_s4q11 == 2) if !mi(pp_s4q11)
gen pesticide_use   = (pp_s4q05 == 1) if !mi(pp_s4q05)
gen herbicide_use   = (pp_s4q06 == 1) if !mi(pp_s4q06)
gen fungicide_use   = (pp_s4q07 == 1) if !mi(pp_s4q07)
gen crop_damaged_pre      = (pp_s4q08 == 1) if !mi(pp_s4q08)
gen crop_damage_cause_pre = pp_s4q09
gen crop_damage_pct_pre   = pp_s4q10
* W3 seed quantity: kg + grams
capture {
    gen _seed_kg = pp_s4q11b_a
    gen _seed_g  = pp_s4q11b_b / 1000
    gen seed_qty_kg = .
    replace seed_qty_kg = cond(mi(_seed_kg), 0, _seed_kg) + ///
                          cond(mi(_seed_g),  0, _seed_g)  ///
        if !mi(_seed_kg) | !mi(_seed_g)
    drop _seed_kg _seed_g
}
if _rc != 0 gen seed_qty_kg = .

keep $CROP_W23 plant_month crop_stand crop_area_share improved_seed ///
     pesticide_use herbicide_use fungicide_use ///
     crop_damaged_pre crop_damage_cause_pre crop_damage_pct_pre seed_qty_kg

tempfile w3_crop
save `w3_crop'

* --- 3c. Plot ---
use "$W3PP/sect3_pp_w3.dta", clear
duplicates report $KEYS_W23

gen region = saq01
gen zone   = saq02
gen woreda = saq03

gen plot_area_raw  = pp_s3q02_a
gen area_unit_code = pp_s3q02_c
gen plot_area_sqm  = pp_s3q05_a
gen plot_ha        = pp_s3q05_a / 10000
gen _fallback_ha   = pp_s3q02_a / 10000 if area_unit_code == 4
replace plot_ha    = _fallback_ha if mi(plot_ha) & !mi(_fallback_ha)
drop _fallback_ha
replace plot_ha = . if plot_ha > 50

gen irrigation_ipt = (pp_s3q12 == 1) if !mi(pp_s3q12)
gen irrig_source   = pp_s3q13

* W3 UREA = pp_s3q16 (no suffix), W3 DAP = pp_s3q19 (no suffix)
gen urea_kg = pp_s3q16
gen dap_kg  = pp_s3q19
gen nps_kg  = pp_s3q20a_2     /* NPS: W3 only */
gen total_fertilizer_kg = 0
gen _fert_answered = 0
replace total_fertilizer_kg = total_fertilizer_kg + urea_kg if !mi(urea_kg)
replace _fert_answered = 1 if !mi(urea_kg)
replace total_fertilizer_kg = total_fertilizer_kg + dap_kg  if !mi(dap_kg)
replace _fert_answered = 1 if !mi(dap_kg)
replace total_fertilizer_kg = total_fertilizer_kg + nps_kg  if !mi(nps_kg)
replace _fert_answered = 1 if !mi(nps_kg)
replace total_fertilizer_kg = . if _fert_answered == 0
drop _fert_answered

gen manure_use  = (pp_s3q21 == 1) if !mi(pp_s3q21)
gen compost_use = (pp_s3q23 == 1) if !mi(pp_s3q23)
gen sample_weight = pw_w3

hh_member_labor_days labor_hh_plant, stub(pp_s3q27)
compute_hired_labor labor_hired_plant, ///
    num_men(pp_s3q28_a) day_men(pp_s3q28_b) ///
    num_wom(pp_s3q28_d) day_wom(pp_s3q28_e) ///
    num_chi(pp_s3q28_g) day_chi(pp_s3q28_h)
compute_exchange_labor labor_exchange_plant, ///
    num_men(pp_s3q29_a) day_men(pp_s3q29_b) ///
    num_wom(pp_s3q29_c) day_wom(pp_s3q29_d) ///
    num_chi(pp_s3q29_e) day_chi(pp_s3q29_f)
nan_aware_sum labor_total_plant = labor_hh_plant labor_hired_plant labor_exchange_plant

keep $KEYS_W23 region zone woreda ///
     plot_area_raw area_unit_code plot_area_sqm plot_ha ///
     irrigation_ipt irrig_source ///
     urea_kg dap_kg nps_kg total_fertilizer_kg ///
     manure_use compost_use sample_weight ///
     labor_hh_plant labor_hired_plant labor_exchange_plant labor_total_plant

tempfile w3_plot
save `w3_plot'

* --- 3d. Harvest labor ---
use "$W3PH/sect10_ph_w3.dta", clear
compute_hired_labor labor_hired_harvest, ///
    num_men(ph_s10q01_a) day_men(ph_s10q01_b) ///
    num_wom(ph_s10q01_d) day_wom(ph_s10q01_e) ///
    num_chi(ph_s10q01_g) day_chi(ph_s10q01_h)
hh_member_labor_days labor_hh_harvest, stub(ph_s10q02)
compute_exchange_labor labor_exchange_harvest, ///
    num_men(ph_s10q03_a) day_men(ph_s10q03_b) ///
    num_wom(ph_s10q03_c) day_wom(ph_s10q03_d) ///
    num_chi(ph_s10q03_e) day_chi(ph_s10q03_f)
nan_aware_sum labor_total_harvest = labor_hired_harvest labor_hh_harvest labor_exchange_harvest
collapse (sum) labor_hired_harvest labor_hh_harvest labor_exchange_harvest labor_total_harvest, ///
    by($KEYS_W23)
tempfile w3_labor
save `w3_labor'

* --- 3e. Assemble Wave 3 ---
use `w3_harvest', clear
merge m:1 $CROP_W23 using `w3_crop',  keep(1 3) nogen
merge m:1 $KEYS_W23 using `w3_plot',  keep(1 3) nogen
merge m:1 $KEYS_W23 using `w3_labor', keep(1 3) nogen

gen year = 2015
gen wave = 3
capture rename household_id_w1_link household_id

di "Wave 3 assembled: `=_N' rows"
tabstat harvest_kg irrigation_ipt total_fertilizer_kg nps_kg plot_ha, ///
    stat(n mean sd) col(stat)

save "$OUT/wave3_survey.dta", replace
di "Saved: $OUT/wave3_survey.dta"


* ============================================================================
* SUMMARY ACROSS WAVES
* ============================================================================
report_section "S1 COMPLETE — Survey extraction done for all 3 waves"
di "Output files:"
di "  $OUT/wave1_survey.dta"
di "  $OUT/wave2_survey.dta"
di "  $OUT/wave3_survey.dta"
di ""
di "Next: run S2_extract_geovars.do"
