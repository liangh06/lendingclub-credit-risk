# Column scope & analytical intent

This document records the analytical lens *before* the data is loaded, so it can be
reconciled against measured reality once profiling and loading run. It does **not**
restrict what gets loaded: the pipeline loads every source column as text
(load-nothing-lose-nothing). Scope is applied later, in SQL staging — this is where
we commit to what we will and won't use, and why.

_Status: pre-load intent, dated 2026-07-19. Column-level specifics (exact statuses,
the final leakage list, sparsity cutoffs) are validated against
`docs/01_profiling_notes.md` (GATE 3) and `docs/02_load_log.md` (GATE 5)._

## Business question

Credit risk at origination: for accepted LendingClub loans, characterize what
distinguishes loans that end badly, using **only information a lender knows at
application time**. This at-origination framing is the primary lens because it is
the one that survives scrutiny — it forbids the look-ahead bias of "predicting" an
outcome from fields that encode it.

Descriptive outcome reporting (e.g. realized charge-off rate by grade or vintage)
is still in scope, but is always presented as **realized outcomes**, never as a
predictor or risk driver.

## Model scope & limitations (selection bias)

The data covers **accepted loans only** — every row was already approved and funded
under LendingClub's own acceptance policy. Any model therefore learns
`P(default | accepted, features)`, not `P(default | applied, features)`: the rejected
applicants, and how they would have performed, are unobserved.

So this project's honest, unbiased lens is **investor / portfolio risk on booked
loans** — "given LendingClub funded this loan, how risky is it?" — for which the
accepted sample is the correct population. It is **not** an origination / underwriting
scorecard ("should we accept this applicant?"): applying an accepts-trained model to
the full through-the-door applicant pool is selection-biased. Correcting for that
would require **reject inference** against the rejected-applications data, which has
no outcome labels (rejected loans were never funded) — so the bias can be mitigated,
not truly removed.

Other known biases to state, not hide: maturity/survivorship (handled — keep unsettled
loans, define the target only on settled), temporal drift across 2007–2018 (incl. the
2008 crisis), and `int_rate`/`grade` endogeneity (LendingClub's own pricing).

## Grain

One row per accepted loan.

## Target definition

The outcome is derived from `loan_status`, restricted to **settled** loans — loans
whose final result is known. You can only label a loan whose ending you have
observed; labeling an in-progress loan would import the future into the present.

Intended mapping (exact tokens and counts confirmed at GATE 3):

- **Good** = `Fully Paid` (and its "Does not meet the credit policy. Status: Fully
  Paid" legacy variant).
- **Bad** = `Charged Off`, `Default` (and the "Does not meet the credit policy.
  Status: Charged Off" variant).
- **Excluded from the target** = unresolved statuses (`Current`, `In Grace Period`,
  `Late (16-30 days)`, `Late (31-120 days)`) — no settled outcome, so they cannot be
  labeled without look-ahead. (`Issued` was anticipated but does **not** appear in
  this file.)

The "Does not meet the credit policy" prefix is treated as an origination-channel
marker, not a distinct outcome: the settled result is still Fully Paid / Charged Off.

_Reconciled at GATE 3 (2026-07-19): the mapping holds against the measured tokens.
Settled base = **1,348,099** loans (**1,078,739 good / 269,360 bad ≈ 20.0% bad**);
912,569 unresolved; 33 empty. Note `Default` is tiny (40 rows)._

## Feature scope

Analytical columns are grouped by whether the information exists **at origination**:

- **In scope (known at application):** loan terms (amount, term, interest rate,
  grade/sub-grade), borrower attributes (employment length, home ownership, annual
  income, income verification), and credit-bureau features as of application
  (e.g. `dti`, revolving utilization, open accounts, delinquency history).
- **Excluded as leakage (post-origination outcomes):** repayment history,
  recoveries, last-/next-payment fields, total payments received, and collection
  fields. These encode the outcome and cannot be inputs to an at-origination view.
  They remain available for clearly-labeled *realized-outcome* reporting only. The
  precise leakage list is finalized against the measured column set at GATE 3.
- **Excluded as non-analytical:** free-text (`desc`, `emp_title`, `title`) and
  identifiers used for joins, not as features.

## Out of scope (this phase)

- The rejected-loans dataset (this project uses accepted loans only).
- Any imputation, encoding, or modeling — this phase is faithful ingestion; typing,
  cleaning, and analysis happen in later, separately-documented sessions.

## Open decisions to reconcile at GATE 3 / GATE 5

- [x] Exact settled `loan_status` tokens and their counts — confirmed at GATE 3
  (see the reconciliation note above).
- [ ] **Exclude export-footer / near-empty junk in staging.** The file is a
  concatenation of export segments, each ending with a `Total amount funded in policy
  code 1/2` footer pair — **≈32 such footer rows (16 pairs) scattered through the
  file**, plus 1 genuinely near-empty row (together, the 33 rows with empty
  `loan_status`/`home_ownership`). All are structurally valid 151-field records and
  load as-is into `loans_raw`; each has a **non-numeric `id`** and unsettled (empty)
  `loan_status`, so staging excludes them via a documented filter (numeric `id`
  and/or settled `loan_status`). The raw table stays a faithful mirror; cleaning
  happens downstream. _(Confirmed by post-load inspection at GATE 5 — the profiler's
  tail-only view had shown just the final pair.)_
- [ ] Final leakage-exclusion list against the measured column set.
- [ ] Columns too sparse to use — decided from the emptiness census, not assumed now.
