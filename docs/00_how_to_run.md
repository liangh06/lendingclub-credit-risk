# How to run the ingestion pipeline

This is the reproduce-from-scratch guide for loading the raw LendingClub CSV into
Postgres. It assumes nothing about prior state beyond a clone of this repo and the
source file. If a step needs something external (a running database, the raw CSV),
that is called out — the scripts never invent credentials or data.

## Prerequisites

- **Python 3.12+** and **PostgreSQL 14+** running and reachable.
- The raw CSV placed at `data/raw/accepted_2007_to_2018Q4.csv`. It is immutable and
  gitignored (~1.6 GB); obtain it from the source (the `wordsforthewise` LendingClub
  mirror) and drop it in — do not edit or re-encode it.

## One-time setup

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1          # PowerShell;  source .venv/bin/activate on *nix
pip install -r requirements.txt

Copy-Item .env.example .env          # then edit .env and set DB_PASSWORD
```

Create the target database (the loader will not create it for you):

```sql
CREATE DATABASE lending;
```

## The pipeline

Run in order. Each step is independent, re-runnable, and writes a generated
artifact you can inspect before moving on. Generated files are never hand-edited —
fix the script and re-run.

| # | Command | Produces | Touches DB? |
|---|---------|----------|-------------|
| 1 | `python scripts/00_profile_csv.py`  | `docs/01_profiling_notes.md` | No |
| 2 | `python scripts/01_generate_ddl.py` | `sql/01_create_raw.sql`      | No |
| 3 | `python scripts/02_load_raw.py`     | `public.loans_raw`, `docs/02_load_log.md` | Yes |

**1. Profile** — measures the file (size, hash, encoding, columns, value sets,
emptiness). Read the notes before generating any schema.

**2. Generate DDL** — emits `CREATE TABLE loans_raw` from the file's header (every
column `text`, every identifier quoted). Confirm its column count matches the
profile's.

**3. Load** — applies the DDL and streams the CSV into `loans_raw` via native
`COPY`. Re-run with `--force` to drop and reload:

```powershell
python scripts/02_load_raw.py --force
```

## Verifying a load

After step 3, `docs/02_load_log.md` should show:
- `sent == COPY rowcount == count(*)` (reconciliation passed, or the load raises),
- zero NULLs in `loans_raw`,
- every source column present in `information_schema` (the load-nothing guarantee),
- any malformed rows listed with line number and content.

## Troubleshooting

- **Connection fails** → the loader prints the exact driver error and stops. Check
  `.env` and that Postgres is running; the script will not guess credentials.
- **`loans_raw already exists`** → re-run with `--force`.
- **Malformed rows reported** → expected and non-fatal; they are logged and skipped.
  Inspect them in the load log.
