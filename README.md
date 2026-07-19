# LendingClub Credit-Risk Analysis

Credit-risk analysis of LendingClub's public **accepted-loans** dataset
(2007–2018): raw CSV → Postgres → SQL staging → Power BI. The project is built to
be read, not just run — every non-obvious decision is documented where it is made.

## Status

> Honest state of the repo. Sections describe only what has actually run.

- [x] **Scaffold** — repo structure, environment, ignored raw data.
- [ ] **Ingestion** — load the raw CSV into Postgres as all-text, verified.
- [ ] **Staging (SQL)** — typed/cleaned model with documented null and cast rules.
- [ ] **Dashboard (Power BI)** — credit-risk views over the staged model.

Row counts, column counts, and value formats are **measured, not assumed** — they
are recorded by the profiler (`docs/01_profiling_notes.md`) once it runs, and are
intentionally not quoted here until then.

## Design spine

The pipeline is built on one guarantee — **load nothing away, lose nothing**:

- **`loans_raw` holds every source column, as `text`.** Column selection and type
  decisions happen later, in SQL staging, where they can be documented. Nothing an
  analysis might need is dropped at load time.
- **Zero nulls in `loans_raw`.** Empty cells load as empty strings, so every
  "this is missing" judgment becomes an explicit, reviewable `NULLIF` in staging
  rather than a silent coercion at the door.
- **The raw CSV is immutable.** A load or cast failure is information to report,
  never a reason to edit the source. Cleaning happens in SQL, downstream of the
  untouched raw table.

## Data

- **Source:** LendingClub accepted loans, 2007–2018 (the `wordsforthewise`
  Kaggle mirror, `accepted_2007_to_2018Q4.csv`).
- **Placement:** the raw CSV lives in `data/raw/` and is **gitignored** — it is
  ~1.5 GB and reproduced from source, not stored in the repo.

## Layout

```
data/raw/     immutable source CSV (gitignored; .gitkeep tracks the dir)
scripts/      ingestion pipeline (profile → generate DDL → load)
sql/          generated + authored SQL (raw-table DDL, later staging)
docs/         decision docs + generated profiling/load records
powerbi/      report screenshots (the .pbix itself is gitignored)
```

## Reproduce

1. Obtain `accepted_2007_to_2018Q4.csv` and place it in `data/raw/`.
2. `python -m venv .venv` and install: `pip install -r requirements.txt`.
3. `cp .env.example .env`, set `DB_PASSWORD`, and create the `lending` database.
4. Run the pipeline (see `docs/00_how_to_run.md`).

_Detailed run instructions live in `docs/00_how_to_run.md`._
