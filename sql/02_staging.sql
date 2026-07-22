-- ============================================================================
-- 02_staging.sql — build the typed, analysis-ready `loans` table from loans_raw.
--
-- WHY THIS EXISTS
--   loans_raw is a faithful, all-text mirror with zero NULLs. This is where that
--   raw fidelity is deliberately turned into an *interpreted* model: text becomes
--   typed values, empty strings become explicit NULLs, and the analytical
--   decisions from docs/00_staging_column_map.md are applied. Every choice here is
--   reversible — the table is rebuilt from the untouched raw layer, so this script
--   IS the record of how raw became analysis-ready.
--
-- DECISIONS EMBODIED (see docs/00_staging_column_map.md, docs/00_column_scope.md)
--   * Row scope: real loans only (`id ~ '^[0-9]+$'` drops the ~33 footer/junk
--     rows). Unsettled loans are KEPT; the target is defined only on settled loans.
--   * Column scope: 85 at-origination features + id + loan_status. Leakage
--     (post-origination), free-text, and ~95%+ empty blocks stay in loans_raw.
--   * NULLIF(col,'') at every cast AND on every text passthrough: the raw
--     zero-NULL invariant becomes explicit, documented NULLs here — no silent
--     coercion. (Text passthroughs were originally missed — caught in review when
--     146,907 empty-string emp_length values surfaced in `loans`; the convention
--     now applies uniformly to every column except the PK `id`.)
--   * Counts are float-formatted in source ('5.0'), so integers cast via
--     ::numeric::int. Dates are Mon-YYYY. term/emp_length are normalized.
--   * "Months since last event": empty = *never happened* -> NULL, plus a
--     has_prior_* flag so "never" is captured as signal, not missingness.
--
-- A failing cast here is information, not a nuisance: it would mean a value in a
-- real-loan row that the profiler did not anticipate. Investigate it, don't paper
-- over it.
--
-- Re-runnable: drops and rebuilds `loans`. Run after 01_create_raw.sql is loaded.
-- ============================================================================

-- The BI view (05_bi_view.sql) joins this table, so it must be dropped before the
-- table can be rebuilt. Recreate it by running 05_bi_view.sql afterwards.
DROP VIEW IF EXISTS public.vw_loans_bi;
DROP TABLE IF EXISTS public.loans;

CREATE TABLE public.loans AS
SELECT
    -- ---- keys & target ---------------------------------------------------
    "id",
    NULLIF("loan_status", '')                                 AS loan_status,
    ("loan_status" IN (
        'Fully Paid', 'Charged Off', 'Default',
        'Does not meet the credit policy. Status:Fully Paid',
        'Does not meet the credit policy. Status:Charged Off'
    ))                                                        AS is_settled,
    CASE
        WHEN "loan_status" IN ('Fully Paid',
             'Does not meet the credit policy. Status:Fully Paid')   THEN 'good'
        WHEN "loan_status" IN ('Charged Off', 'Default',
             'Does not meet the credit policy. Status:Charged Off')  THEN 'bad'
        ELSE NULL  -- unsettled: no known outcome, cannot be labeled
    END                                                       AS loan_outcome,

    -- ---- loan terms ------------------------------------------------------
    NULLIF("loan_amnt", '')::numeric                          AS loan_amnt,
    NULLIF("funded_amnt", '')::numeric                        AS funded_amnt,
    NULLIF(regexp_replace("term", '[^0-9]', '', 'g'), '')::int AS term_months,
    NULLIF("int_rate", '')::numeric                           AS int_rate,
    NULLIF("installment", '')::numeric                        AS installment,
    NULLIF("grade", '')                                       AS grade,
    NULLIF("sub_grade", '')                                   AS sub_grade,

    -- ---- borrower / application -----------------------------------------
    NULLIF("emp_length", '')                                  AS emp_length,
    CASE
        WHEN "emp_length" IN ('', 'n/a')     THEN NULL
        WHEN "emp_length" = '< 1 year'       THEN 0
        ELSE NULLIF(regexp_replace("emp_length", '[^0-9]', '', 'g'), '')::int
    END                                                       AS emp_length_years,
    NULLIF("home_ownership", '')                              AS home_ownership,
    NULLIF("annual_inc", '')::numeric                         AS annual_inc,
    NULLIF("verification_status", '')                         AS verification_status,
    NULLIF("application_type", '')                            AS application_type,
    NULLIF("purpose", '')                                     AS purpose,

    -- ---- geography & dates ----------------------------------------------
    NULLIF("addr_state", '')                                  AS addr_state,
    to_date(NULLIF("issue_d", ''), 'Mon-YYYY')                AS issue_d,
    to_date(NULLIF("earliest_cr_line", ''), 'Mon-YYYY')       AS earliest_cr_line,
    round((to_date(NULLIF("issue_d", ''), 'Mon-YYYY')
         - to_date(NULLIF("earliest_cr_line", ''), 'Mon-YYYY'))::numeric
         / 365.25, 1)                                         AS credit_history_years,

    -- ---- credit bureau @ application (amounts / ratios) -----------------
    NULLIF("dti", '')::numeric                                AS dti,
    NULLIF("revol_bal", '')::numeric                          AS revol_bal,
    NULLIF("revol_util", '')::numeric                         AS revol_util,
    NULLIF("tot_coll_amt", '')::numeric                       AS tot_coll_amt,
    NULLIF("tot_cur_bal", '')::numeric                        AS tot_cur_bal,
    NULLIF("total_rev_hi_lim", '')::numeric                   AS total_rev_hi_lim,
    NULLIF("avg_cur_bal", '')::numeric                        AS avg_cur_bal,
    NULLIF("bc_open_to_buy", '')::numeric                     AS bc_open_to_buy,
    NULLIF("bc_util", '')::numeric                            AS bc_util,
    NULLIF("delinq_amnt", '')::numeric                        AS delinq_amnt,
    NULLIF("tot_hi_cred_lim", '')::numeric                    AS tot_hi_cred_lim,
    NULLIF("total_bal_ex_mort", '')::numeric                  AS total_bal_ex_mort,
    NULLIF("total_bc_limit", '')::numeric                     AS total_bc_limit,
    NULLIF("total_il_high_credit_limit", '')::numeric         AS total_il_high_credit_limit,
    NULLIF("pct_tl_nvr_dlq", '')::numeric                     AS pct_tl_nvr_dlq,
    NULLIF("percent_bc_gt_75", '')::numeric                   AS percent_bc_gt_75,

    -- ---- credit bureau @ application (counts) ---------------------------
    NULLIF("delinq_2yrs", '')::numeric::int                   AS delinq_2yrs,
    NULLIF("fico_range_low", '')::numeric::int                AS fico_range_low,
    NULLIF("fico_range_high", '')::numeric::int               AS fico_range_high,
    NULLIF("inq_last_6mths", '')::numeric::int                AS inq_last_6mths,
    NULLIF("open_acc", '')::numeric::int                      AS open_acc,
    NULLIF("pub_rec", '')::numeric::int                       AS pub_rec,
    NULLIF("total_acc", '')::numeric::int                     AS total_acc,
    NULLIF("collections_12_mths_ex_med", '')::numeric::int    AS collections_12_mths_ex_med,
    NULLIF("acc_now_delinq", '')::numeric::int                AS acc_now_delinq,
    NULLIF("acc_open_past_24mths", '')::numeric::int          AS acc_open_past_24mths,
    NULLIF("chargeoff_within_12_mths", '')::numeric::int      AS chargeoff_within_12_mths,
    NULLIF("mort_acc", '')::numeric::int                      AS mort_acc,
    NULLIF("pub_rec_bankruptcies", '')::numeric::int          AS pub_rec_bankruptcies,
    NULLIF("tax_liens", '')::numeric::int                     AS tax_liens,
    NULLIF("num_accts_ever_120_pd", '')::numeric::int         AS num_accts_ever_120_pd,
    NULLIF("num_actv_bc_tl", '')::numeric::int                AS num_actv_bc_tl,
    NULLIF("num_actv_rev_tl", '')::numeric::int               AS num_actv_rev_tl,
    NULLIF("num_bc_sats", '')::numeric::int                   AS num_bc_sats,
    NULLIF("num_bc_tl", '')::numeric::int                     AS num_bc_tl,
    NULLIF("num_il_tl", '')::numeric::int                     AS num_il_tl,
    NULLIF("num_op_rev_tl", '')::numeric::int                 AS num_op_rev_tl,
    NULLIF("num_rev_accts", '')::numeric::int                 AS num_rev_accts,
    NULLIF("num_rev_tl_bal_gt_0", '')::numeric::int           AS num_rev_tl_bal_gt_0,
    NULLIF("num_sats", '')::numeric::int                      AS num_sats,
    NULLIF("num_tl_120dpd_2m", '')::numeric::int              AS num_tl_120dpd_2m,
    NULLIF("num_tl_30dpd", '')::numeric::int                  AS num_tl_30dpd,
    NULLIF("num_tl_90g_dpd_24m", '')::numeric::int            AS num_tl_90g_dpd_24m,
    NULLIF("num_tl_op_past_12m", '')::numeric::int            AS num_tl_op_past_12m,

    -- ---- account-age "months since" (generally populated) ---------------
    NULLIF("mo_sin_old_il_acct", '')::numeric::int            AS mo_sin_old_il_acct,
    NULLIF("mo_sin_old_rev_tl_op", '')::numeric::int          AS mo_sin_old_rev_tl_op,
    NULLIF("mo_sin_rcnt_rev_tl_op", '')::numeric::int         AS mo_sin_rcnt_rev_tl_op,
    NULLIF("mo_sin_rcnt_tl", '')::numeric::int                AS mo_sin_rcnt_tl,
    NULLIF("mths_since_recent_bc", '')::numeric::int          AS mths_since_recent_bc,
    NULLIF("mths_since_recent_inq", '')::numeric::int         AS mths_since_recent_inq,

    -- ---- extended inquiry/installment bureau (2015+ vintages) -----------
    NULLIF("open_acc_6m", '')::numeric::int                   AS open_acc_6m,
    NULLIF("open_act_il", '')::numeric::int                   AS open_act_il,
    NULLIF("open_il_12m", '')::numeric::int                   AS open_il_12m,
    NULLIF("open_il_24m", '')::numeric::int                   AS open_il_24m,
    NULLIF("mths_since_rcnt_il", '')::numeric::int            AS mths_since_rcnt_il,
    NULLIF("total_bal_il", '')::numeric                       AS total_bal_il,
    NULLIF("il_util", '')::numeric                            AS il_util,
    NULLIF("open_rv_12m", '')::numeric::int                   AS open_rv_12m,
    NULLIF("open_rv_24m", '')::numeric::int                   AS open_rv_24m,
    NULLIF("max_bal_bc", '')::numeric                         AS max_bal_bc,
    NULLIF("all_util", '')::numeric                           AS all_util,
    NULLIF("inq_fi", '')::numeric::int                        AS inq_fi,
    NULLIF("total_cu_tl", '')::numeric::int                   AS total_cu_tl,
    NULLIF("inq_last_12m", '')::numeric::int                  AS inq_last_12m,

    -- ---- "months since last event": empty = never (value + has_prior flag)
    NULLIF("mths_since_last_delinq", '')::numeric::int        AS mths_since_last_delinq,
    ("mths_since_last_delinq" <> '')                          AS has_prior_delinq,
    NULLIF("mths_since_last_record", '')::numeric::int        AS mths_since_last_record,
    ("mths_since_last_record" <> '')                          AS has_prior_pub_rec,
    NULLIF("mths_since_last_major_derog", '')::numeric::int   AS mths_since_last_major_derog,
    ("mths_since_last_major_derog" <> '')                     AS has_prior_derog,
    NULLIF("mths_since_recent_bc_dlq", '')::numeric::int      AS mths_since_recent_bc_dlq,
    NULLIF("mths_since_recent_revol_delinq", '')::numeric::int AS mths_since_recent_revol_delinq

FROM public.loans_raw
WHERE "id" ~ '^[0-9]+$';   -- real loans only; drops footer/near-empty junk

-- id is unique across real loans (verified: 2,260,668 distinct == row count).
ALTER TABLE public.loans ADD PRIMARY KEY ("id");
