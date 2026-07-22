-- ============================================================================
-- 04_analysis.sql — credit-risk analysis over the staged model. READ-ONLY.
--
-- WHY THIS EXISTS
--   The findings that justify the dashboard, written as reproducible SQL rather
--   than clicked together in a BI tool. Each query answers one question and
--   doubles as a staging sanity check: if a number here looks wrong, it points
--   back at a staging decision, not at a chart.
--
-- CONVENTIONS (each one fixes a bug caught in review)
--   * ONE population per row: every metric in a query is computed over the SAME
--     loan set. Where outcomes are involved that set is SETTLED loans — mixing
--     all-loan averages with settled-only rates in one row drifted results by up
--     to 0.6pp per grade in the first draft.
--   * Net return is reported BOTH ways and labeled: avg_return_per_loan
--     (equal-weighted: the average loan's return) and portfolio_return
--     (dollar-weighted: sum(profit)/sum(funded) — return per dollar invested).
--     They differ because small loans are overweighted by the per-loan average.
--     Total-period, not annualized. NOTE net_profit = total_pymnt - funded_amnt;
--     total_pymnt already includes recoveries (row-level verified), so recoveries
--     are NOT added separately (doing so previously overstated return).
--   * No silent exclusions: rows that can't be banded (NULL / sentinel values)
--     are shown as their own labeled bands, not filtered away. dti carries
--     sentinels (-1, 999) and 1,711 NULLs; they are visible below.
--   * "Bad rate" = bad / (good + bad), on settled loans only — an unresolved
--     loan has no outcome to rate.
--   * Vintage analysis reports % settled alongside, because recent vintages are
--     under-matured (2018 is 11.4% settled) — the maturity caveat made visible.
-- ============================================================================

-- 04.1  Portfolio snapshot ---------------------------------------------------
SELECT is_settled,
       count(*)                                    AS loans,
       count(*) FILTER (WHERE loan_outcome='good') AS good,
       count(*) FILTER (WHERE loan_outcome='bad')  AS bad
FROM public.loans
GROUP BY is_settled ORDER BY is_settled;

-- 04.2  Risk & realized return by grade (settled loans; the headline curve) ---
SELECT l.grade,
       count(*)                                                  AS settled,
       round(avg(l.int_rate), 2)                                 AS avg_int_rate,
       round(100.0*count(*) FILTER (WHERE l.loan_outcome='bad')
              / count(*), 2)                                     AS bad_rate_pct,
       round(100*avg(p.net_profit/NULLIF(p.funded_amnt,0)), 2)   AS avg_return_per_loan_pct,
       round(100*sum(p.net_profit)/sum(p.funded_amnt), 2)        AS portfolio_return_pct
FROM public.loans l
JOIN public.loan_performance p USING (id)
WHERE l.is_settled
GROUP BY l.grade ORDER BY l.grade;

-- 04.3  Risk by term (settled loans) ------------------------------------------
SELECT term_months,
       count(*)                                                  AS settled,
       round(avg(int_rate), 2)                                   AS avg_int_rate,
       round(100.0*count(*) FILTER (WHERE loan_outcome='bad')
              / count(*), 2)                                     AS bad_rate_pct
FROM public.loans
WHERE is_settled
GROUP BY term_months ORDER BY term_months;

-- 04.4  Bad rate by vintage (all loans, with maturity caveat) -----------------
SELECT extract(year FROM issue_d)::int                           AS issue_year,
       count(*)                                                  AS loans,
       round(100.0*count(*) FILTER (WHERE is_settled)
              / count(*), 1)                                     AS pct_settled,
       round(100.0*count(*) FILTER (WHERE loan_outcome='bad')
              / NULLIF(count(*) FILTER (WHERE is_settled),0), 2) AS bad_rate_pct
FROM public.loans
GROUP BY 1 ORDER BY 1;

-- 04.5  Bad rate by DTI band (settled; NULL/sentinel rows shown, not dropped) -
SELECT CASE WHEN dti IS NULL THEN '0a: missing'
            WHEN dti < 0    THEN '0b: sentinel (<0)'
            WHEN dti < 10   THEN '1: <10'
            WHEN dti < 20   THEN '2: 10-20'
            WHEN dti < 30   THEN '3: 20-30'
            WHEN dti < 40   THEN '4: 30-40'
            ELSE                 '5: 40+ (incl. 999 sentinel)' END AS dti_band,
       count(*)                                                  AS settled,
       round(100.0*count(*) FILTER (WHERE loan_outcome='bad')
              / count(*), 2)                                     AS bad_rate_pct
FROM public.loans
WHERE is_settled
GROUP BY dti_band ORDER BY dti_band;

-- 04.6  Bad rate by FICO band (settled; <660 is tiny — LC rarely funded there) -
SELECT CASE WHEN fico_range_low < 660 THEN '1: <660'
            WHEN fico_range_low < 690 THEN '2: 660-689'
            WHEN fico_range_low < 720 THEN '3: 690-719'
            WHEN fico_range_low < 750 THEN '4: 720-749'
            ELSE                           '5: 750+' END          AS fico_band,
       count(*)                                                  AS settled,
       round(100.0*count(*) FILTER (WHERE loan_outcome='bad')
              / count(*), 2)                                     AS bad_rate_pct
FROM public.loans
WHERE is_settled
GROUP BY fico_band ORDER BY fico_band;

-- 04.7  Bad rate by home ownership (settled; small categories kept visible) ----
SELECT home_ownership,
       count(*)                                                  AS settled,
       round(100.0*count(*) FILTER (WHERE loan_outcome='bad')
              / count(*), 2)                                     AS bad_rate_pct
FROM public.loans
WHERE is_settled
GROUP BY home_ownership ORDER BY settled DESC;
