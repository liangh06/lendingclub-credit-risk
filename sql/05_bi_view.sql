-- ============================================================================
-- 05_bi_view.sql — the contract between Postgres and Power BI.
--
-- WHY THIS EXISTS
--   Power BI imports THIS view, not the base tables. Three reasons:
--   * Column scope: the dashboard needs ~27 columns, not loans' 94 + performance's
--     20. Importing the bureau tail would bloat the model for fields no visual uses.
--   * Pre-join: loans and loan_performance are 1:1 on id (same grain), so the join
--     belongs here — a Power BI relationship between two same-grain tables adds
--     memory and modeling surface for zero analytical gain.
--   * Bands in SQL, not DAX: dti_band / fico_band reuse the exact CASE logic of
--     04_analysis.sql, so the dashboard and the SQL findings can never disagree
--     about what "20-30" means, and the logic stays version-controlled here.
--
--   Measures (bad rate, portfolio return) are deliberately NOT pre-computed here:
--   ratios must be computed AFTER slicer filters, so they live as DAX measures
--   over row-level values (see docs/03_powerbi_model.md).
--
-- Plain (non-materialized) view: Import mode reads it once per refresh; a full
-- scan at refresh time is acceptable and always reflects the current tables.
-- ============================================================================

CREATE OR REPLACE VIEW public.vw_loans_bi AS
SELECT
    -- identity & outcome
    l.id,
    l.loan_status,
    l.is_settled,
    l.loan_outcome,

    -- loan terms
    l.grade,
    l.sub_grade,
    l.term_months,
    l.int_rate,
    l.loan_amnt,
    l.funded_amnt,
    l.installment,

    -- time
    l.issue_d,
    extract(year FROM l.issue_d)::int AS issue_year,

    -- borrower & application
    l.purpose,
    l.home_ownership,
    l.addr_state,
    l.verification_status,
    l.application_type,
    l.emp_length_years,
    l.annual_inc,
    l.credit_history_years,

    -- risk drivers + bands (same logic as 04_analysis.sql)
    l.dti,
    CASE WHEN l.dti IS NULL THEN '0a: missing'
         WHEN l.dti < 0    THEN '0b: sentinel (<0)'
         WHEN l.dti < 10   THEN '1: <10'
         WHEN l.dti < 20   THEN '2: 10-20'
         WHEN l.dti < 30   THEN '3: 20-30'
         WHEN l.dti < 40   THEN '4: 30-40'
         ELSE                   '5: 40+' END AS dti_band,
    l.fico_range_low,
    CASE WHEN l.fico_range_low < 660 THEN '1: <660'
         WHEN l.fico_range_low < 690 THEN '2: 660-689'
         WHEN l.fico_range_low < 720 THEN '3: 690-719'
         WHEN l.fico_range_low < 750 THEN '4: 720-749'
         ELSE                             '5: 750+' END AS fico_band,

    -- realized economics (meaningful for settled loans; DAX measures gate on
    -- is_settled — out_prncp is the exception, it is the *unsettled* book)
    p.net_profit,
    p.total_pymnt,
    p.out_prncp
FROM public.loans l
JOIN public.loan_performance p USING (id);
