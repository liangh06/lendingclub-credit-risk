# Staging column map — loans_raw → loans

The explicit, per-column decision for the typed `loans` table. Every one of the
151 source columns is either **IN** (typed into `loans`) or **OUT** (left in
`loans_raw`, with a reason). This is the leakage boundary and sparsity cutoff made
concrete — the thing a reviewer should be able to challenge column by column.

_Authored decision doc (dated 2026-07-19). Scope: at-origination credit risk;
post-origination fields are leakage and excluded from the typed model but remain
available in `loans_raw`._

## Row scope
`loans` = all real loans (`id ~ '^[0-9]+$'`, excludes the ~33 junk/footer rows) —
**2,260,668 rows**. Unsettled loans are kept (portfolio views + correct handling of
maturity bias); the target is defined only on settled loans via the flags below.

## Handling conventions
- **Empty → NULL** at the typing boundary: `NULLIF(col,'')` before every cast. This
  is where the raw table's zero-NULL invariant is deliberately converted into
  explicit, documented NULLs.
- **Counts are float-formatted** in the source (`'5.0'`), so integer casts go via
  `NULLIF(col,'')::numeric::int` (a direct `::int` on `'5.0'` errors).
- **Dates** are `Mon-YYYY`: `to_date(NULLIF(col,''),'Mon-YYYY')`.
- **`term`** `' 36 months'` → `36` (int months).
- **`emp_length`** → `emp_length_years` int: `'10+ years'`→10, `'< 1 year'`→0,
  `'n/a'`/`''`→NULL; raw kept too.
- **"Months since" fields**: empty = *never happened* → NULL, plus a companion
  `has_prior_*` boolean so "never" is captured as signal, not missingness.

## Derived columns (added in `loans`)
| Column | Definition |
|---|---|
| `is_settled` | `loan_status` ∈ {Fully Paid, Charged Off, Default, + the two "Does not meet credit policy" variants} |
| `loan_outcome` | `'good'` (Fully Paid + DNMCP-FullyPaid) / `'bad'` (Charged Off, Default, DNMCP-ChargedOff) / `NULL` when not settled |
| `emp_length_years` | numeric emp length (see conventions) |
| `credit_history_years` | `issue_d − earliest_cr_line`, in years |
| `has_prior_delinq`, `has_prior_pub_rec`, `has_prior_derog` | booleans from the months-since fields |

## IN — typed into `loans` (≈85 features + `id` + `loan_status`)

**Keys / outcome (2):** `id` (text, PK), `loan_status` (text → drives `is_settled`,
`loan_outcome`).

**Loan terms (7):** `loan_amnt` num, `funded_amnt` num, `term` int-months,
`int_rate` num, `installment` num, `grade` text, `sub_grade` text.
_(int_rate/grade are LendingClub's own risk pricing — central to the dashboard, kept, circularity noted where it matters.)_

**Borrower / application (6):** `emp_length` (text + `emp_length_years`),
`home_ownership` text, `annual_inc` num, `verification_status` text,
`application_type` text, `purpose` text.

**Geography / dates (3):** `addr_state` text, `issue_d` date, `earliest_cr_line`
date (→ `credit_history_years`).

**Credit bureau @ application (~50):** `dti`, `delinq_2yrs`, `fico_range_low`,
`fico_range_high`, `inq_last_6mths`, `open_acc`, `pub_rec`, `revol_bal`,
`revol_util`, `total_acc`, `collections_12_mths_ex_med`, `acc_now_delinq`,
`tot_coll_amt`, `tot_cur_bal`, `total_rev_hi_lim`, `acc_open_past_24mths`,
`avg_cur_bal`, `bc_open_to_buy`, `bc_util`, `chargeoff_within_12_mths`,
`delinq_amnt`, `mo_sin_old_il_acct`, `mo_sin_old_rev_tl_op`, `mo_sin_rcnt_rev_tl_op`,
`mo_sin_rcnt_tl`, `mort_acc`, `mths_since_recent_bc`, `mths_since_recent_inq`,
`num_accts_ever_120_pd`, `num_actv_bc_tl`, `num_actv_rev_tl`, `num_bc_sats`,
`num_bc_tl`, `num_il_tl`, `num_op_rev_tl`, `num_rev_accts`, `num_rev_tl_bal_gt_0`,
`num_sats`, `num_tl_120dpd_2m`, `num_tl_30dpd`, `num_tl_90g_dpd_24m`,
`num_tl_op_past_12m`, `pct_tl_nvr_dlq`, `percent_bc_gt_75`, `pub_rec_bankruptcies`,
`tax_liens`, `tot_hi_cred_lim`, `total_bal_ex_mort`, `total_bc_limit`,
`total_il_high_credit_limit`.

**Extended inquiry/installment bureau (~14, ~21% empty = pre-2015 vintages):**
`open_acc_6m`, `open_act_il`, `open_il_12m`, `open_il_24m`, `mths_since_rcnt_il`,
`total_bal_il`, `il_util`, `open_rv_12m`, `open_rv_24m`, `max_bal_bc`, `all_util`,
`inq_fi`, `total_cu_tl`, `inq_last_12m`.

**"Months since" — empty = never (5):** `mths_since_last_delinq`,
`mths_since_last_record`, `mths_since_last_major_derog`, `mths_since_recent_bc_dlq`,
`mths_since_recent_revol_delinq` (each NULL-on-empty + companion `has_prior_*` flag).

## OUT — left in `loans_raw` only (≈64)

**Leakage — post-origination outcomes (15):** `out_prncp`, `out_prncp_inv`,
`total_pymnt`, `total_pymnt_inv`, `total_rec_prncp`, `total_rec_int`,
`total_rec_late_fee`, `recoveries`, `collection_recovery_fee`, `last_pymnt_d`,
`last_pymnt_amnt`, `next_pymnt_d`, `last_credit_pull_d`, `last_fico_range_high`,
`last_fico_range_low`. _These encode the outcome; using them as predictors is leakage._

**Free-text / identifiers (5):** `emp_title`, `desc`, `title`, `url`, `member_id`
(`member_id` 100% empty).

**Constant / operational (4):** `policy_code` (constant), `pymnt_plan`,
`initial_list_status`, `disbursement_method` (near-constant servicing flags).

**Redundant / high-cardinality (2):** `funded_amnt_inv` (≈`funded_amnt`),
`zip_code` (use `addr_state`).

**Sparse — joint / secondary applicant, ~95% empty (16):** `annual_inc_joint`,
`dti_joint`, `verification_status_joint`, `revol_bal_joint`, and all 12 `sec_app_*`.

**Sparse — hardship program, ~99% empty (15):** `hardship_flag`, `hardship_type`,
`hardship_reason`, `hardship_status`, `deferral_term`, `hardship_amount`,
`hardship_start_date`, `hardship_end_date`, `payment_plan_start_date`,
`hardship_length`, `hardship_dpd`, `hardship_loan_status`,
`orig_projected_additional_accrued_interest`, `hardship_payoff_balance_amount`,
`hardship_last_payment_amount`.

**Sparse — debt settlement, ~98% empty + post-orig (7):** `debt_settlement_flag`,
`debt_settlement_flag_date`, `settlement_status`, `settlement_date`,
`settlement_amount`, `settlement_percentage`, `settlement_term`.

## Reconciliation
IN (85 features + `id` + `loan_status` = 87) + OUT (64) = **151** ✔ every source
column has an explicit decision.
