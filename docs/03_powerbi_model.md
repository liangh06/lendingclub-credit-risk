# Power BI model — import, relationships, measures

The `.pbix` binary is gitignored, so **this document is the version-controlled
definition of the Power BI model**: what gets imported, how the model is shaped,
and the exact DAX for every measure. Anyone (including a reviewer) can rebuild the
dashboard from this file; screenshots in `powerbi/screenshots/` are the visual
record.

## Import

- **Source:** PostgreSQL connector → server `localhost:5432`, database `lending`.
- **Object:** `public.vw_loans_bi` **only** (28 columns; the view is the BI
  contract — see `sql/05_bi_view.sql`). Do not import the base tables.
- **Mode: Import** (not DirectQuery). 2.26M rows of mostly low-cardinality
  columns compress well in VertiPaq; the data is a static historical snapshot, so
  a scheduled/manual refresh is all that's needed, and visuals stay instant.

## Data model

**Single table — deliberately minimal.** `vw_loans_bi` is the only table (grain:
one row per loan), because the view pre-joined `loans` + `loan_performance` 1:1.

- **Vintage grain is year, and the view already exposes `issue_year` (int).** Use
  that column directly for all vintage visuals — a separate date dimension is not
  needed for this dashboard, so it is intentionally omitted (don't add machinery
  the analysis won't use). Recommended: turn OFF Power BI's auto date/time (File →
  Options → Data Load) to drop the hidden per-date-column tables.
- **Optional — only if month/quarter drill or time-intelligence measures are later
  wanted:** add a DAX date table and relate it 1:* to `issue_d`:

  ```dax
  DimDate = CALENDAR(DATE(2007,1,1), DATE(2019,3,31))
  ```

  Mark as date table (Table tools → Mark as date table, column `Date`). Not
  required for the agreed 4-page layout.

Model hygiene: hide `id` from report view (it's a key, not an analytical field);
set `issue_year`, `term_months`, `fico_range_low` to "Don't summarize"; format
`int_rate`, `dti` as numbers not currency.

## Measures (the only place ratios are computed)

Ratios must be computed **after** slicer filters — a pre-averaged column is wrong
the moment a user clicks a slicer. Hence: no pre-aggregated columns anywhere;
every ratio is a measure over row-level values. `DIVIDE()` returns BLANK on a zero
denominator (an empty slicer selection) instead of erroring.

The settled-population discipline from `04_analysis.sql` carries over: **every
outcome measure gates on `is_settled`**.

```dax
Loans           = COUNTROWS(vw_loans_bi)

Settled Loans   = CALCULATE([Loans], vw_loans_bi[is_settled] = TRUE())

Bad Loans       = CALCULATE([Loans], vw_loans_bi[loan_outcome] = "bad")

Good Loans      = CALCULATE([Loans], vw_loans_bi[loan_outcome] = "good")

Bad Rate %      = DIVIDE([Bad Loans], [Settled Loans])
-- format: percentage, 1 decimal. Denominator is settled, not all loans:
-- an unresolved loan has no outcome to rate.

Pct Settled %   = DIVIDE([Settled Loans], [Loans])
-- the maturity caveat as a measure: show beside any vintage bad rate.

Funded $        = SUM(vw_loans_bi[funded_amnt])

Settled Funded $ = CALCULATE([Funded $], vw_loans_bi[is_settled] = TRUE())

Net Profit $    = CALCULATE(SUM(vw_loans_bi[net_profit]),
                            vw_loans_bi[is_settled] = TRUE())
-- gated on settled: net_profit of a Current loan understates its eventual value.

Portfolio Return % = DIVIDE([Net Profit $], [Settled Funded $])
-- dollar-weighted (sum/sum): return per dollar invested. This is the honest
-- portfolio number (grade F: 0.52% vs 1.20% equal-weighted).

Avg Return per Loan % =
    CALCULATE(
        AVERAGEX(vw_loans_bi,
                 DIVIDE(vw_loans_bi[net_profit], vw_loans_bi[funded_amnt])),
        vw_loans_bi[is_settled] = TRUE())
-- equal-weighted companion; label clearly wherever both appear.

Avg Int Rate %  = CALCULATE(AVERAGE(vw_loans_bi[int_rate]),
                            vw_loans_bi[is_settled] = TRUE()) / 100
-- settled-gated so it describes the same population as Bad Rate % when they
-- share a visual (the mixed-population bug from the SQL audit, pre-empted here).

Outstanding Principal $ = SUM(vw_loans_bi[out_prncp])
-- the live book: nonzero only for unsettled loans; do NOT gate on settled.
```

## Page layout (agreed design)

Four pages; each answers one reviewer question. Global slicers on every page:
`grade`, `term_months`, `issue_year` (from DimDate), `purpose`.

**1 · Portfolio Overview — "What is this book?"**
- KPI card row: `Loans` · `Funded $` · `Pct Settled %` · `Bad Rate %` ·
  `Portfolio Return %`
- Combo: loan volume by issue year (columns) + `Pct Settled %` (line) — the
  maturity story up front
- Mix: funded $ by `grade`; loans by `purpose` (bar, not pie — 12+ categories)

**2 · Risk & Return by Grade — the centerpiece**
- Combo (main visual): x = grade A→G; columns = `Bad Rate %` (climbs 6%→50%);
  line = `Portfolio Return %` (peaks at B ≈6.2%, negative at G). The divergence
  IS the finding.
- Companion: `Avg Int Rate %` vs `Bad Rate %` by grade — pricing vs realized risk
- Matrix: grade × {settled, bad rate, portfolio return, avg return per loan} —
  both weightings visible and labeled
- Clustered bar: `Bad Rate %` by `term_months` (the 2× finding)

**3 · Risk Drivers — "What predicts a bad loan?"**
- Four bars of `Bad Rate %`: by `fico_band`, `dti_band`, `home_ownership`,
  `emp_length_years`. Cross-filtering ON — clicking a FICO band re-slices the
  rest (the interactive version of 04_analysis.sql)
- Keep the `0a: missing` DTI band visible — no silent exclusions on the
  dashboard either

**4 · Vintage & Geography — "When and where?"**
- Combo: `Bad Rate %` by issue year (columns) + `Pct Settled %` (line); annotate
  2008 (crisis vintages) and 2016 (peak). The line is the guard against reading
  2018's low bar as quality.
- Filled map: `Bad Rate %` by `addr_state`
- Footnote on this page especially: recent-vintage rates are provisional

Every page footer: "Settled loans only for outcome metrics · returns are
total-period, not annualized · accepted loans only (see docs/00_column_scope.md)".

Screenshots of the finished pages go to `powerbi/screenshots/` (the reviewable
artifact; the .pbix stays untracked).

## Known caveats to carry onto the report (as footnotes/tooltips)

- Returns are **total-period, not annualized** — do not compare 36- vs 60-month
  returns as if per-year.
- Recent vintages are under-matured: any vintage visual must show `Pct Settled %`
  alongside (2018 is 11.4% settled; its low bad rate is survivorship, not quality).
- Data is accepted loans only (selection bias): this is investor/portfolio
  analytics, not an underwriting scorecard — see `docs/00_column_scope.md`.
