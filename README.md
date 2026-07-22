# LendingClub Credit-Risk Analysis

Credit-risk analysis of LendingClub's public **accepted-loans** dataset
(2007–2018, ~2.26M loans): raw CSV → Postgres → typed SQL staging → Power BI. The
project is built to be **read, not just run** — every non-obvious decision is
documented where it is made, and the commit history is a decision narrative.

**Framing (and its honest limits):** this is **investor / portfolio credit-risk
analytics on booked loans** — "given LendingClub funded this loan, how risky is
it, and what did it return?" It is *not* an underwriting scorecard: the data is
accepted loans only, so any model is conditioned on LendingClub's own acceptance
decision (selection bias). See [`docs/00_column_scope.md`](docs/00_column_scope.md).

## Status

> Honest state of the repo. Sections describe only what has actually run.

- [x] **Scaffold** — structure, environment, gitignored raw data.
- [x] **Ingestion** — all 151 source columns loaded to `loans_raw` as text, zero
      NULLs, reconciled and verified (`docs/02_load_log.md`).
- [x] **Staging (SQL)** — typed `loans` (features + target) and `loan_performance`
      (economics), with a documented leakage boundary and cast rules.
- [x] **Analysis** — reproducible finding queries (`sql/04_analysis.sql`).
- [~] **Dashboard (Power BI)** — data model, DAX measures, and 4-page layout fully
      specified (`docs/03_powerbi_model.md`) and the import view built
      (`sql/05_bi_view.sql`); the `.pbix` build + screenshots are in progress.

## Design spine

**Load nothing away, lose nothing.** `loans_raw` holds *every* source column as
`text` with *zero* NULLs — empty cells load as empty strings, so every missingness
call becomes an explicit, reviewable `NULLIF` in staging rather than a silent
coercion at the door. The raw CSV is immutable; a load/cast failure is information
to report, never a reason to edit the source. Column selection and typing are
deferred to staging, where they are documented.

**Leakage boundary, made structural.** The typed `loans` table carries only
*at-origination* features + the target; post-origination outcome fields (payments,
recoveries, …) live in a *separate* `loan_performance` table. A model on `loans`
physically cannot reach a leakage field, but `loans JOIN loan_performance USING
(id)` answers realized-return questions.

## Data model

```
loans_raw          151 cols · all text · zero-NULL     (2,260,701)  immutable mirror
  ├─ loans          94 cols · typed · at-origination + target (2,260,668)  risk drivers
  └─ loan_performance  20 cols · typed economics · keyed by id (2,260,668)  realized ROI
vw_loans_bi         the Power BI import contract (pre-joined, 28 cols)
```

The `loans`/`loan_performance` split excludes the ~33 export-footer junk rows via
`id ~ '^[0-9]+$'`; the target (`loan_outcome` good/bad) is defined only on **settled**
loans, with unsettled loans kept for portfolio views (and to avoid maturity bias).

## Selected findings (settled loans)

- **Risk climbs, return doesn't follow it down the grade ladder:** bad rate rises
  6% (A) → 50% (G), but dollar-weighted net return is **highest at grades A–B
  (~5.4% / 5.3%) and turns negative from grade E down (E −1.2%, G −8.6%)** — the
  fatter coupons on lower grades don't cover their defaults.
- **60-month loans carry ~2× the default rate** of 36-month (32% vs 16%).
- **FICO and DTI are cleanly monotonic** risk drivers (FICO: 31% → 9% bad).
- **Recent vintages are under-matured** — 2018 is only 11.4% settled, so its low
  bad rate is survivorship; every vintage view carries `% settled` as a caveat.

## Layout

```
data/raw/     immutable source CSV (gitignored; .gitkeep tracks the dir)
scripts/      ingestion: 00 profile → 01 generate DDL → 02 load
sql/          01 create_raw · 02 staging · 03 performance · 04 analysis · 05 bi_view
docs/         decision docs + generated profiling/load records + Power BI model spec
powerbi/      report screenshots (the .pbix itself is gitignored)
```

## Reproduce

1. Obtain `accepted_2007_to_2018Q4.csv` and place it in `data/raw/`.
2. `python -m venv .venv` && `pip install -r requirements.txt`.
3. `cp .env.example .env`, set `DB_PASSWORD`, create the `lending` database.
4. Ingestion: `python scripts/00_profile_csv.py` → `01_generate_ddl.py` →
   `02_load_raw.py`. Staging: run `sql/02_staging.sql` → `03` → `05` in Postgres.

Detailed run instructions: [`docs/00_how_to_run.md`](docs/00_how_to_run.md).

## Tech

Python 3.12 (stdlib `csv` streaming + `psycopg`) · PostgreSQL 14+ · Power BI.
Deliberately minimal dependencies — see `requirements.txt`.
