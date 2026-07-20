-- ============================================================================
-- 03_performance.sql — build loan_performance: realized loan economics, keyed by id.
--
-- WHY THIS EXISTS (and why it's a SEPARATE table from `loans`)
--   Net return / ROI is a realized-outcome question — it needs the post-origination
--   cash-flow fields that `loans` deliberately excludes as leakage. Rather than
--   weaken `loans` or re-derive these casts ad-hoc in every query, the outcome
--   columns are typed ONCE here, in their own table, joined to `loans` on `id`.
--   The separation makes the leakage boundary STRUCTURAL: a model built on `loans`
--   physically cannot pull a return field, but `loans JOIN loan_performance USING
--   (id)` gives realized economics whenever they're legitimately wanted.
--
-- SCOPE / CAVEATS
--   * Same row scope as `loans`: real loans only (id ~ '^[0-9]+$').
--   * net_profit / ROI are meaningful for SETTLED loans. For Current loans, cash
--     received is partial and `out_prncp` is still outstanding, so their net_profit
--     understates eventual return — filter `is_settled` (from `loans`) for return
--     analysis. This layer stays agnostic and just carries the atomic facts.
--   * Debt-settlement and hardship blocks are deliberately NOT staged here.
--     Recovery requires TWO stages of seasoning — the loan must default, and then a
--     settlement/recovery process must run its course — so recent vintages cannot
--     support LGD analysis at all (2018 loans are barely past origination). The
--     recovered CASH is already captured by `recoveries`, which is what net_profit
--     needs; the settlement MECHANISM fields (status, %, dates) would only serve an
--     LGD track this snapshot can't properly support. They remain in loans_raw and
--     can be staged later if a seasoned-vintage (pre-2016) LGD study is scoped.
--     Hardship is excluded for volume: 832 loans, ~0.04%.
--   * Only per-row atomic fields + net_profit live here. Aggregated ROI % is left
--     to Power BI DAX measures so it stays filter-aware (an averaged pre-computed
--     ratio does not respect slicers). Annualization (36- vs 60-month) is also an
--     analysis-layer choice, not baked in here.
--
-- Re-runnable: drops and rebuilds loan_performance. Run after 02_staging.sql.
-- ============================================================================

DROP TABLE IF EXISTS public.loan_performance;

CREATE TABLE public.loan_performance AS
SELECT
    "id",

    -- investment base (denominator for ROI; duplicated from source for a
    -- self-contained economics table)
    NULLIF("funded_amnt", '')::numeric        AS funded_amnt,
    NULLIF("funded_amnt_inv", '')::numeric    AS funded_amnt_inv,

    -- outstanding principal (still to be collected — nonzero mainly for Current)
    NULLIF("out_prncp", '')::numeric          AS out_prncp,
    NULLIF("out_prncp_inv", '')::numeric      AS out_prncp_inv,

    -- cash received to date, and its components
    NULLIF("total_pymnt", '')::numeric        AS total_pymnt,
    NULLIF("total_pymnt_inv", '')::numeric    AS total_pymnt_inv,
    NULLIF("total_rec_prncp", '')::numeric    AS total_rec_prncp,
    NULLIF("total_rec_int", '')::numeric      AS total_rec_int,
    NULLIF("total_rec_late_fee", '')::numeric AS total_rec_late_fee,
    NULLIF("recoveries", '')::numeric         AS recoveries,
    NULLIF("collection_recovery_fee", '')::numeric AS collection_recovery_fee,

    -- payment timeline + updated (behavioral) FICO
    to_date(NULLIF("last_pymnt_d", ''), 'Mon-YYYY')       AS last_pymnt_d,
    NULLIF("last_pymnt_amnt", '')::numeric                AS last_pymnt_amnt,
    to_date(NULLIF("next_pymnt_d", ''), 'Mon-YYYY')       AS next_pymnt_d,
    to_date(NULLIF("last_credit_pull_d", ''), 'Mon-YYYY') AS last_credit_pull_d,
    NULLIF("last_fico_range_low", '')::numeric::int       AS last_fico_range_low,
    NULLIF("last_fico_range_high", '')::numeric::int      AS last_fico_range_high,

    -- derived: total cash back and per-row net profit (recoveries added to
    -- payments; COALESCE so a missing recoveries counts as 0, not NULL)
    (NULLIF("total_pymnt", '')::numeric
        + COALESCE(NULLIF("recoveries", '')::numeric, 0))            AS total_cash_received,
    (NULLIF("total_pymnt", '')::numeric
        + COALESCE(NULLIF("recoveries", '')::numeric, 0)
        - NULLIF("funded_amnt", '')::numeric)                       AS net_profit

FROM public.loans_raw
WHERE "id" ~ '^[0-9]+$';

-- 1:1 with loans on id; PK enforces uniqueness and makes the join efficient.
ALTER TABLE public.loan_performance ADD PRIMARY KEY ("id");
