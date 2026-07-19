"""
Load the raw LendingClub CSV into Postgres as all-text — the load-nothing-lose-
nothing step.

WHY THIS EXISTS
    This is the one place the untouched source becomes queryable. Everything the
    project can ever claim rests on this load being complete and honest, so the
    script is built to prove — not assume — that it moved every column and every
    settled record faithfully, and to leave a written record when it couldn't.

THE THREE DECISIONS AN INTERVIEWER WILL PROBE
    1. It loads EVERY column, as text, into loans_raw. Column selection is a
       staging decision made later against the full raw table; nothing an
       analysis needs can be blocked by a column we declined to load.
    2. Empty cells load as empty STRINGS, not NULLs (COPY ... FORCE_NOT_NULL on
       every column). loans_raw therefore contains zero NULLs — which means every
       future "this value is missing" is an explicit, documented NULLIF in SQL
       staging, never a silent coercion smuggled in at load time.
    3. Malformed records (wrong field count) are LOGGED with their line number
       and content, then SKIPPED — never dropped silently, never allowed to abort
       a 2M-row load. A bad row is data-quality evidence, not a fatal error and
       not something to hide.

    It streams with the csv module (not pandas): a 1.6 GB file is never
    materialized in memory. Python parses each record once — validating its field
    count — and hands the validated record to a native COPY stream.

    Reconciliation is enforced with `raise`, not `assert`, so the guarantee holds
    even under `python -O` (which strips asserts). A load that doesn't reconcile
    must fail, loudly.

OUTPUT
    public.loans_raw          (the table)
    docs/02_load_log.md       (generated — do not hand-edit; re-run to refresh)

USAGE
    python scripts/02_load_raw.py [--force]
        --force  drop and recreate loans_raw if it already exists
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

try:
    import psycopg
except ModuleNotFoundError:
    sys.exit("psycopg not installed. Run: pip install -r requirements.txt")

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

REPO = Path(__file__).resolve().parents[1]
RAW_DIR = REPO / "data" / "raw"
DDL_FILE = REPO / "sql" / "01_create_raw.sql"
LOG = REPO / "docs" / "02_load_log.md"

TABLE = "public.loans_raw"


def find_raw_csv() -> Path:
    candidates = sorted(RAW_DIR.glob("*.csv"), key=lambda p: p.stat().st_size, reverse=True)
    if not candidates:
        sys.exit(f"No *.csv found in {RAW_DIR}")
    return candidates[0]


def read_header(path: Path) -> list[str]:
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        return next(csv.reader(f))


def quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def connect() -> "psycopg.Connection":
    """Connect strictly from .env. Fail fast with the EXACT driver error — never
    guess credentials or fall back to defaults."""
    load_dotenv(REPO / ".env")
    required = ["DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"]
    missing = [k for k in required if os.environ.get(k) in (None, "")]
    if missing:
        sys.exit(f"Missing required .env values: {', '.join(missing)} "
                 f"(copy .env.example to .env and fill them in)")
    try:
        return psycopg.connect(
            host=os.environ["DB_HOST"],
            port=os.environ["DB_PORT"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
        )
    except psycopg.OperationalError as e:
        sys.exit(f"Database connection failed (exact error below — not retried):\n{e}")


def ensure_table(cur, force: bool) -> None:
    """Apply the generated DDL. Refuse to clobber an existing table unless
    --force says so explicitly."""
    if not DDL_FILE.exists():
        sys.exit(f"Missing {DDL_FILE.relative_to(REPO)} — run scripts/01_generate_ddl.py first")
    cur.execute("SELECT to_regclass(%s)", (TABLE,))
    exists = cur.fetchone()[0] is not None
    if exists and not force:
        sys.exit(f"{TABLE} already exists. Re-run with --force to drop and reload.")
    if exists:
        print(f"--force: dropping existing {TABLE}")
        cur.execute(f"DROP TABLE {TABLE}")
    cur.execute(DDL_FILE.read_text(encoding="utf-8"))


def load(cur, path: Path, header: list[str]) -> dict:
    """Stream valid records into a native COPY; log-and-skip malformed ones.

    Every field from csv.reader is a str (never None), and FORCE_NOT_NULL turns
    empty CSV fields into '' rather than NULL — together these are why loans_raw
    ends up with zero NULLs."""
    ncol = len(header)
    collist = ", ".join(quote_ident(c) for c in header)
    copy_sql = (
        f"COPY {TABLE} ({collist}) FROM STDIN "
        f"WITH (FORMAT csv, FORCE_NOT_NULL ({collist}))"
    )

    # Reused buffer: re-serialize each validated record to one canonical CSV line
    # so the ONLY parser Postgres ever sees is our own. Python parses, canonicalizes,
    # Postgres re-parses the canonical form — no two parsers disagreeing on raw input.
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n")

    sent = 0
    malformed: list[tuple[int, list[str]]] = []
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        next(reader)  # skip header; loans_raw columns come from the DDL
        with cur.copy(copy_sql) as copy:
            for row in reader:
                if len(row) != ncol:
                    malformed.append((reader.line_num, row))
                    continue
                buf.seek(0)
                buf.truncate(0)
                writer.writerow(row)
                copy.write(buf.getvalue())
                sent += 1
        physical_lines = reader.line_num  # includes header + multi-line records

    return {"sent": sent, "malformed": malformed, "loaded": cur.rowcount,
            "physical_lines": physical_lines}


def reconcile(cur, result: dict) -> int:
    """Sent == COPY rowcount == table count. Any disagreement is fatal."""
    cur.execute(f"SELECT count(*) FROM {TABLE}")
    table_count = cur.fetchone()[0]
    sent, loaded = result["sent"], result["loaded"]
    if not (sent == loaded == table_count):
        raise RuntimeError(
            f"Reconciliation FAILED: sent={sent:,} copy_rowcount={loaded:,} "
            f"table_count={table_count:,} — refusing to certify this load."
        )
    return table_count


def verify_no_nulls(cur) -> None:
    """A row `r IS NOT NULL` is true only if every field is non-null, so this
    counts fully-non-null rows. It must equal the total, or the zero-null
    guarantee is broken."""
    cur.execute(f"SELECT count(*) FROM {TABLE}")
    total = cur.fetchone()[0]
    cur.execute(f"SELECT count(*) FROM {TABLE} WHERE {TABLE.split('.')[-1]} IS NOT NULL")
    non_null_rows = cur.fetchone()[0]
    if non_null_rows != total:
        raise RuntimeError(
            f"Zero-NULL guarantee BROKEN: {total - non_null_rows:,} rows contain a NULL."
        )


def db_column_list(cur) -> list[str]:
    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema='public' AND table_name='loans_raw' "
        "ORDER BY ordinal_position"
    )
    return [r[0] for r in cur.fetchall()]


def write_log(cur, path: Path, header: list[str], result: dict, table_count: int) -> None:
    L: list[str] = []
    w = L.append
    w("# Load log — public.loans_raw\n")
    w(f"> GENERATED by `scripts/02_load_raw.py` at "
      f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}. Do not hand-edit.\n")
    w(f"- Source: `{path.relative_to(REPO)}`")

    w("\n## Reconciliation\n")
    w(f"- Physical lines read (incl. header, incl. multi-line records): **{result['physical_lines']:,}**")
    w(f"- Records sent (valid): **{result['sent']:,}**")
    w(f"- COPY rowcount: **{result['loaded']:,}**")
    w(f"- `count(*)` in table: **{table_count:,}**")
    w(f"- Malformed skipped: **{len(result['malformed']):,}**")
    w("- sent == COPY rowcount == count(*): **verified** (load would have raised otherwise)")
    w("- Zero NULLs in loans_raw: **verified**")

    w("\n## Malformed records excluded (complete list)\n")
    if result["malformed"]:
        w("| physical line | field count | content |")
        w("|---|---|---|")
        for line_no, row in result["malformed"]:
            w(f"| {line_no} | {len(row)} | `{row!r}` |")
    else:
        w("_None — every record matched the header's field count._")

    if "loan_status" in header:
        w("\n## Complete `loan_status` distribution\n")
        w("| loan_status | count |")
        w("|---|---|")
        cur.execute(f'SELECT "loan_status", count(*) FROM {TABLE} '
                    f'GROUP BY "loan_status" ORDER BY count(*) DESC')
        for val, cnt in cur.fetchall():
            w(f"| `{val!r}` | {cnt:,} |")

    if "id" in header:
        w("\n## Blank `id`\n")
        cur.execute(f"SELECT count(*) FILTER (WHERE \"id\" = ''), count(*) FROM {TABLE}")
        blank, total = cur.fetchone()
        pct = 100 * blank / total if total else 0
        w(f"- Blank ids: **{blank:,}** of {total:,} (**{pct:.2f}%**)")

    dbcols = db_column_list(cur)
    w(f"\n## Proof: every source column is present in loans_raw ({len(dbcols)})\n")
    if len(dbcols) != len(header):
        raise RuntimeError(
            f"Column count mismatch: header={len(header)} vs table={len(dbcols)}."
        )
    for i, col in enumerate(dbcols, 1):
        w(f"{i}. `{col}`")

    LOG.write_text("\n".join(L) + "\n", encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description="Load the raw LendingClub CSV as all-text.")
    ap.add_argument("--force", action="store_true",
                    help="drop and recreate loans_raw if it already exists")
    args = ap.parse_args()

    path = find_raw_csv()
    header = read_header(path)
    print(f"Loading {path.name} ({len(header)} columns) into {TABLE} ...")

    conn = connect()
    try:
        with conn.cursor() as cur:
            ensure_table(cur, args.force)
            result = load(cur, path, header)
            table_count = reconcile(cur, result)
            verify_no_nulls(cur)
            write_log(cur, path, header, result, table_count)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    print(f"Loaded {table_count:,} records; {len(result['malformed']):,} malformed skipped.")
    print(f"Wrote {LOG.relative_to(REPO)}")


if __name__ == "__main__":
    main()
