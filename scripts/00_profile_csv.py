"""
Profile the raw LendingClub CSV — READ-ONLY, no database.

WHY THIS EXISTS
    Before a single value is loaded or cast, we need an evidence record of what
    the file actually contains: its exact size and hash, how it is encoded and
    framed, every column it carries, and the raw shape of the values a later
    step will have to interpret. This script produces that record and nothing
    else. It touches no database and makes no schema decisions, so profiling can
    never be contaminated by, or contaminate, the load.

THE DESIGN TRADEOFF IT EMBODIES
    The notes it writes contain MEASUREMENTS ONLY — never expectations. We record
    "the first raw value of `int_rate` is '13.56%'", not "int_rate looks like a
    percentage we should strip". Casting decisions are made later, in SQL
    staging, and must be justified by what is written here. Keeping this file
    free of assumptions is what lets the profiling notes serve as the neutral
    ground truth the rest of the project is argued from.

    It reads the ~1.6 GB file by streaming (one binary pass for identity, one csv
    pass for structure); it never loads the whole file into memory.

OUTPUT
    docs/01_profiling_notes.md  (generated — do not hand-edit; re-run to refresh)
"""

from __future__ import annotations

import csv
import hashlib
import sys
from collections import Counter
from pathlib import Path

# LendingClub's free-text columns (desc, emp_title) can hold long values; lift
# the csv field cap so a legitimate long field is never a parse error. Clamp to
# a C-long-safe value on Windows.
csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

REPO = Path(__file__).resolve().parents[1]
RAW_DIR = REPO / "data" / "raw"
OUT = REPO / "docs" / "01_profiling_notes.md"

# Columns a later staging step is LIKELY to cast (numeric, percent, date, unit).
# This list only decides which columns get a close-up of their raw values — it
# asserts nothing about their format. Columns absent from the file are skipped.
CAST_TARGET_CANDIDATES = [
    "id", "loan_amnt", "funded_amnt", "term", "int_rate", "installment",
    "grade", "sub_grade", "emp_length", "annual_inc", "dti", "revol_util",
    "issue_d", "earliest_cr_line", "last_pymnt_d", "next_pymnt_d",
    "last_credit_pull_d",
]

# Low-cardinality columns whose full value set is worth enumerating exactly.
CATEGORICAL_COLS = [
    "loan_status", "home_ownership", "grade", "term", "purpose",
    "verification_status", "emp_length",
]

CLOSEUP_MAX_VALUES = 8      # distinct raw values shown per cast-target column
MALFORMED_PREVIEW = 20      # field-count anomalies previewed inline
TAIL_BYTES = 8192           # trailing bytes scanned for the file's last lines


def find_raw_csv() -> Path:
    """Auto-select the largest *.csv in data/raw/ so the profiler is not pinned
    to a hardcoded filename."""
    candidates = sorted(RAW_DIR.glob("*.csv"), key=lambda p: p.stat().st_size, reverse=True)
    if not candidates:
        sys.exit(f"No *.csv found in {RAW_DIR}")
    return candidates[0]


def scan_identity(path: Path) -> dict:
    """One binary pass: size, SHA-256, BOM, line-ending style, physical newline
    count, and whether the file ends with a newline. Byte-level facts only."""
    sha = hashlib.sha256()
    newlines = 0
    first_chunk = b""
    last_byte = b""
    with path.open("rb") as f:
        while chunk := f.read(1 << 20):
            if not first_chunk:
                first_chunk = chunk[:4]
            sha.update(chunk)
            newlines += chunk.count(b"\n")
            last_byte = chunk[-1:]
    has_bom = first_chunk.startswith(b"\xef\xbb\xbf")
    # If any \n is preceded by \r the file uses CRLF framing.
    line_ending = "CRLF (\\r\\n)" if b"\r\n" in first_chunk or _sniff_crlf(path) else "LF (\\n)"
    return {
        "size": path.stat().st_size,
        "sha256": sha.hexdigest(),
        "has_bom": has_bom,
        "line_ending": line_ending,
        "newlines": newlines,
        "ends_with_newline": last_byte == b"\n",
    }


def _sniff_crlf(path: Path) -> bool:
    with path.open("rb") as f:
        return b"\r\n" in f.read(65536)


def read_tail_lines(path: Path, n: int = 5) -> list[str]:
    """Last few PHYSICAL lines, read from the file's tail. Exposes trailing
    summary/junk rows some LendingClub exports append after the data."""
    size = path.stat().st_size
    with path.open("rb") as f:
        f.seek(max(0, size - TAIL_BYTES))
        tail = f.read()
    text = tail.decode("utf-8", errors="replace")
    return [ln for ln in text.splitlines() if ln != ""][-n:]


def scan_structure(path: Path) -> dict:
    """One csv pass: header, true parsed record count, per-column emptiness,
    first raw value per column, cast-target close-ups, categorical value sets,
    and field-count anomalies. Uses the csv module so embedded newlines inside
    quoted fields are handled correctly."""
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        ncol = len(header)

        records = 0
        malformed = []                       # (physical_line, field_count, preview)
        empties = [0] * ncol
        first_value: list[str | None] = [None] * ncol
        cat_idx = {c: header.index(c) for c in CATEGORICAL_COLS if c in header}
        cat_counts = {c: Counter() for c in cat_idx}
        closeup_idx = {c: header.index(c) for c in CAST_TARGET_CANDIDATES if c in header}
        closeup_vals: dict[str, list[str]] = {c: [] for c in closeup_idx}

        for row in reader:
            records += 1
            if len(row) != ncol:
                if len(malformed) < MALFORMED_PREVIEW:
                    malformed.append((reader.line_num, len(row), row[:6]))
                continue  # can't align cells to columns, so skip stats for this row
            for i, val in enumerate(row):
                if val == "":
                    empties[i] += 1
                elif first_value[i] is None:
                    first_value[i] = val
            for c, i in cat_idx.items():
                cat_counts[c][row[i]] += 1
            for c, i in closeup_idx.items():
                v = row[i]
                if v not in closeup_vals[c] and len(closeup_vals[c]) < CLOSEUP_MAX_VALUES:
                    closeup_vals[c].append(v)

    return {
        "header": header,
        "ncol": ncol,
        "records": records,
        "malformed": malformed,
        "empties": empties,
        "first_value": first_value,
        "cat_counts": cat_counts,
        "closeup_vals": closeup_vals,
    }


def write_notes(path: Path, ident: dict, struct: dict, tail: list[str]) -> None:
    header = struct["header"]
    ncol = struct["ncol"]
    records = struct["records"]
    L = []
    w = L.append

    w("# Profiling notes — raw LendingClub CSV\n")
    w("> GENERATED by `scripts/00_profile_csv.py`. Do not hand-edit; re-run to refresh.\n")
    w("> These are **measurements only** — a record of what the file *is*, not what\n"
      "> it *should* become. Every cast/clean decision downstream must cite a fact here.\n")

    w(f"\n## File identity\n")
    w(f"- Path: `{path.relative_to(REPO)}`")
    w(f"- Size: {ident['size']:,} bytes")
    w(f"- SHA-256: `{ident['sha256']}`")

    w(f"\n## Encoding & framing\n")
    w(f"- UTF-8 BOM present: **{ident['has_bom']}**")
    w(f"- Line ending: **{ident['line_ending']}**")
    w(f"- Ends with trailing newline: **{ident['ends_with_newline']}**")
    w(f"- Physical `\\n` count: **{ident['newlines']:,}**  "
      f"_(reference, NOT the record count — quoted fields can contain newlines)_")

    w(f"\n## Record structure\n")
    w(f"- Columns (from header): **{ncol}**")
    w(f"- Data records parsed by csv (excludes header): **{records:,}**")
    n_mal = len(struct["malformed"])
    w(f"- Records whose field count != {ncol}: **{n_mal}{'+' if n_mal == MALFORMED_PREVIEW else ''}** "
      f"(preview capped at {MALFORMED_PREVIEW}; the loader logs the complete set)")
    if struct["malformed"]:
        w("\n| physical line | field count | first cells |")
        w("|---|---|---|")
        for line_no, cnt, preview in struct["malformed"]:
            w(f"| {line_no} | {cnt} | `{preview!r}` |")

    w(f"\n## Full column list ({ncol})\n")
    for i, col in enumerate(header, 1):
        w(f"{i}. `{col}`")

    w(f"\n## First raw value per column (repr)\n")
    w("_repr() exposes leading/trailing spaces, `%`, and unit suffixes._\n")
    w("| # | column | first non-empty value |")
    w("|---|---|---|")
    for i, col in enumerate(header, 1):
        fv = struct["first_value"][i - 1]
        w(f"| {i} | `{col}` | `{fv!r}` |")

    w(f"\n## Cast-target close-ups\n")
    w("_First distinct raw values for columns likely to be cast later._\n")
    for c, vals in struct["closeup_vals"].items():
        shown = ", ".join(f"`{v!r}`" for v in vals) or "_(none non-empty seen)_"
        w(f"- `{c}`: {shown}")

    w(f"\n## Categorical value sets (exact)\n")
    for c, counts in struct["cat_counts"].items():
        w(f"\n### `{c}` — {len(counts)} distinct")
        w("| value | count |")
        w("|---|---|")
        for val, cnt in counts.most_common():
            w(f"| `{val!r}` | {cnt:,} |")

    w(f"\n## Emptiness census (per column)\n")
    w("| # | column | empty | empty % |")
    w("|---|---|---|---|")
    denom = records or 1
    for i, col in enumerate(header, 1):
        e = struct["empties"][i - 1]
        w(f"| {i} | `{col}` | {e:,} | {100 * e / denom:.1f}% |")

    w(f"\n## Last physical lines of the file\n")
    for ln in tail:
        w(f"- `{ln!r}`")

    w(f"\n## Open questions (to resolve before casting, in SQL staging)\n")
    w("- What is the exact format of each `*_d` date column (e.g. `issue_d`)?")
    w("- Do `int_rate` / `revol_util` carry a trailing `%` that must be stripped?")
    w("- Does `term` carry a leading space and a ` months` suffix?")
    w("- How is a missing `emp_length` represented, and is `n/a` a distinct token?")
    w("- Which `loan_status` values count as a settled outcome? (a judgment call, not a measurement)")
    w("- Are the trailing physical lines real records or an export summary/footer?")

    OUT.write_text("\n".join(L) + "\n", encoding="utf-8")


def main() -> None:
    path = find_raw_csv()
    print(f"Profiling {path} ...")
    ident = scan_identity(path)
    print(f"  identity: {ident['size']:,} bytes, sha256={ident['sha256'][:12]}...")
    struct = scan_structure(path)
    print(f"  structure: {struct['ncol']} columns, {struct['records']:,} records")
    tail = read_tail_lines(path)
    write_notes(path, ident, struct, tail)
    print(f"Wrote {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
