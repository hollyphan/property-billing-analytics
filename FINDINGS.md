# Findings

Running log of insights from each completed analysis file, in order.
See `sql/` for the underlying queries and inline technical comments on
*how* each check works -- this file is the *why it matters* narrative.

## 01 -- Data Cleaning

**Business question:** Before running business-logic exception detection
in file 02, is the raw loaded dataset structurally trustworthy -- free
of missing values, invalid values, illogical dates, and broken
relationships between tables?

**What the data shows:** Across all six tables (150 properties, 6,781
units, 10,870 leases, 27,124 utility accounts, 323,649 charges, 319,325
payments), every check came back clean -- no NULLs in required fields,
no non-positive dollar amounts, no backwards lease dates, no payments
predating their billing period, and no orphaned foreign keys anywhere
in the schema. The one real defect found in this process was a
data-loading bug, not a business-data problem: the source CSVs used
Windows-style line endings that the `LOAD DATA INFILE` statements
didn't account for, leaving an invisible character on every value in
trailing text columns. It silently broke exact-match string
comparisons while staying invisible in numeric columns. Traced to root
cause, fixed in the load script, data reloaded and re-verified.

**So what:** The dataset is structurally sound and ready for
business-logic exception detection. Just as important: two apparent
"problems" turned out to be correct business logic once understood in
context -- a NULL `payment_date` and a $0.00 `amount_paid` both
correlate perfectly with failed payments, representing "this payment
never went through" rather than bad data. Flagging either as an error
would have produced a false finding.

**Recommendation:** Proceed to `02_billing_exceptions.sql`.

**Limitation:** This file confirms structural and referential integrity
only -- it does not (and isn't meant to) catch duplicate charges,
missing billing periods, or proration mismatches. Those are explicitly
out of scope here and belong to file 02.

## 02 -- Billing Exceptions: Duplicate Charges

*(File 02 complete -- duplicate charges, missing charges, and proration errors all detected, validated, and written up below. See `sql/02_billing_exceptions.sql` for the queries.)*

**Business question:** Has the same billing event been charged more than
once to the same utility account in the same billing period?

**What the data shows:** Grouping `charges` on `account_id`,
`billing_period`, `charge_type`, and `amount` -- deliberately including
`charge_type` so a legitimate multi-charge-type billing event (for
example a usage charge and a late fee both posting in the same period)
isn't mistaken for a duplicate -- 12,374 rows fall into a group of two
or more otherwise-identical charges. That figure lines up almost
exactly with the data profile's count of 6,187 account+billing_period
combos flagged as having more than one charge (6,187 x 2 = 12,374),
which is a strong cross-check that the detection grain is catching the
intended duplicates cleanly, without pulling in unrelated multi-charge
periods or missing real duplicates by being too narrow.

**So what:** On live production billing this pattern would mean a
meaningful number of accounts were charged twice for the same utility
service in the same period -- directly eating into the billing accuracy
rate the eventual dashboard (file 05) is meant to track. It's also a
clean, deterministic class of error: unlike a proration mismatch, an
exact duplicate charge has no ambiguity about whether it's a real
defect.

**Recommendation:** Proceed to missing-charge (gap) and proration-error
detection to round out file 02's exception coverage before drawing any
portfolio-level conclusions. This finding stands on its own as an
interview talking point -- why account_id + billing_period alone is the
wrong grain, and how `COUNT(*) OVER (PARTITION BY ...)` surfaces group
size in a single pass instead of a separate aggregate query followed by
a second row-level query.

**Limitation:** This check is intentionally exact-match -- it flags
groups where account_id, billing_period, charge_type, and amount are
all identical, and would not catch a duplicate that was later corrected
to a different amount before detection. It's detection only: there is
no ground-truth label in the data, so this can establish that a
duplicate exists, not why it occurred.

### Missing Charges (Billing Gaps)

**Business question:** For every utility account, during every billing
period its lease was active, does a charge actually exist -- or are
there periods where the account went unbilled?

**What the data shows:** Building an expected-periods scaffold from
each account's lease history (leases → units → utility_accounts, with
periods tested for month-level overlap against lease_start/lease_end
rather than exact date containment, so a lease starting or ending
mid-month still counts as expecting a charge) and anti-joining against
actual charges surfaces 6,790 missing-charge instances across 5,770 of
the 27,124 utility accounts (about 21%). The ratio of instances to
accounts (roughly 1.18) shows this is mostly isolated single-month
gaps spread across many accounts rather than a small number of
chronically broken ones. Two spot checks against the source tables
confirm the logic: account 6 has continuous lease coverage from
2025-05-01 through 2027-10-31 across two back-to-back leases, and is
missing only its February 2026 charge while January and March are
both present. Account 9 has continuous coverage from 2025-05-01
through 2027-04-30 and is missing two consecutive months, April and
May 2026, with no tenancy break to explain it -- a real multi-month
gap rather than a lease-turnover false positive.

**So what:** This is a different failure mode than duplicate charges.
Duplicates were a uniform, mechanical double-bill pattern; missing
charges are more varied -- some accounts skip a single isolated month,
others (like account 9) miss multiple consecutive months, which points
toward an account-specific processing failure or short billing-system
outage rather than a one-off glitch. Operationally the two problems
would be triaged differently: a duplicate charge is a straightforward
reversal or credit, while a missing charge is under-billed revenue
that has to be identified and backfilled before it becomes
uncollectable, particularly the longer it goes undetected.

**Recommendation:** Proceed to proration-error detection, the last
exception type for this file. Account 9's most recent charge is
charge_type 'prorated' rather than 'regular' -- a natural segue into
that check.

**Limitation:** This check only establishes whether any charge row
exists for a given account + billing_period; it doesn't evaluate
whether a gap was later covered by an out-of-sequence backfill charge
recorded under a different billing_period, and it can't explain *why*
a specific gap occurred (system outage vs. isolated processing error)
-- that root-cause distinction isn't recoverable from this dataset's
structure.
### Proration Errors

**Business question:** Are prorated charges being classified correctly
at lease boundaries, and once classified, are their amounts calculated
correctly?

**What the data shows:** 5,105 of 9,537 prorated charges (53.5%) have
`amount <> expected_amount`. This single category accounts for the
entire portfolio-wide amount-variance figure -- all 5,105 variance
charges across the full 323,649-row `charges` table are prorated, and
zero regular charges carry any variance. That reconciles almost
exactly with the data profile's stated 1.6% baseline (5,105 / 323,649
= 1.58%).

Separately, 2,254 charges (0.70% of all charges) are labeled
`prorated` when lease-boundary logic (billing_period fully contained
within lease_start/lease_end) says they should be `regular`. This
mismatch is entirely one-directional -- zero charges are labeled
`regular` when boundary logic says they should be `prorated`.

The two error sets aren't independent: all 2,254 misclassified charges
are a subset of the 5,105 amount-error charges, meaning every
mislabeled charge also has a wrong amount. The remaining 2,851
amount-error charges are correctly labeled `prorated` -- genuine
boundary-crossing charges with a separate calculation defect.

The two groups also differ in the shape of the error itself, not just
in classification. The 2,254 mislabeled charges (Pattern A) have
amount ratios (amount / expected_amount) tightly bounded between 0.50
and 1.80 -- errors run in both directions, over- and under-billing,
roughly comparably. The 2,851 correctly-labeled charges (Pattern B)
are overbilled every time -- ratio never drops below 1.03 -- and range
as high as 31x expected, with the most extreme ratios concentrated
among charges with a small expected_amount (538 of 2,851, about 19%,
have expected_amount under $5; the smallest is $0.69). The mean ratio
for Pattern B (7.08) is distorted by that handful of near-zero-
denominator charges and isn't representative; the mean dollar
difference ($22.61 vs. $14.39 for Pattern A) is the more honest
summary statistic for comparing the two groups.

Spot-checked: charge 132 sits in the middle of a single lease with no
boundary nearby (May 2025-Apr 2027), yet is mislabeled `prorated` with
a moderately wrong amount (44.96 vs. 24.98, ratio 1.80 -- right at
Pattern A's upper bound). Charge 393 falls in a genuine 8-day gap
between two back-to-back leases, is correctly labeled `prorated`, and
is overbilled (45.94 vs. 35.57), consistent with Pattern B's
always-over direction.

**So what:** This is two distinct defects sharing one label, not one
bug showing up twice. Pattern A mislabels non-boundary charges as
prorated for no lease-timing reason, and the amount calculation
appears to inherit that bad label -- the 100% co-occurrence with
amount errors, plus a bounded, both-directions error range, points to
one shared root cause behind the labeling and the amount. Pattern B
affects genuinely boundary-crossing charges that are labeled
correctly, but the proration math itself systematically overbills,
worst on small charges -- consistent with an error that adds (or
scales by) something roughly fixed regardless of the underlying charge
size, rather than a proportional miscalculation. Together these two
patterns account for all amount variance in the dataset; non-prorated
charges are calculated correctly with zero exceptions.

**Recommendation:** Two independent fixes are needed, not one. First,
audit whatever assigns `charge_type = 'prorated'` -- it fires on 2,254
charges with no structural justification, and the amount logic
downstream appears to trust that label rather than actual lease dates.
Second, separately audit the proration amount calculation for charges
that are genuinely boundary-crossing (Pattern B) -- correctly labeled,
but overbilled every time, disproportionately so on small-dollar
charges. Fixing only the labeling issue would leave 2,851 charges --
the larger of the two groups -- still wrong.

**Limitation:** This establishes that both defects exist, that Pattern
B is exclusively an overbilling error, and that its error magnitude
scales inversely with charge size -- but the underlying calculation
logic producing each pattern can't be reverse-engineered from this
dataset alone. The `avg_ratio` distortion is itself worth carrying
forward as a general principle: an average-of-ratios statistic needs a
denominator sanity check before it's reported, since division against
small or near-zero values can produce a headline number that
misrepresents the typical case.

## 03 -- Payment Delinquency: Payment Status Validation

**Business question:** Can the `payments.status` field be trusted as-is to identify delinquent accounts, or does it need independent verification against payment timing?

**What the data shows:** Independently derived payment status (on-time = paid within 5 days after due date, late = 6-60 days past due, failed = beyond 60 days past due or no payment ever recorded) was compared against the stored `status` field for all 319,325 payment records with a payment row (charges with no payment at all are out of scope for this check -- see check 2).

The `failed` label matched perfectly: all 8,534 failed-status payments have a NULL `payment_date`, and the derived logic classified every one of them as failed. Zero disagreement.

The `on-time` and `late` labels disagreed on 29,768 of 319,325 rows (9.3% of all payments). The disagreement runs entirely in one direction -- every mismatch is a payment stored as `late` that independently derives as `on-time`. There is no case of the reverse. That's 29,768 of the 51,257 total late-labeled payments in the dataset: 58% of everything the source data calls "late" actually falls inside the on-time grace window when measured against its own due date.

The mismatched rows span -23 to +5 days from due date (stddev 8.4 days). Traced against `generate_data.py`: the generator computes its own internal due date as `period_start` plus one calendar month -- 29 days earlier than the 30-days-after-period-end convention this check applies (and that's documented as the project's business rule everywhere else). Late payments are placed uniformly at random 6 to 55 days after that internal due date, so measured against the correct 30-day rule the spread becomes a uniform -23 to +26 days -- the 28-day range comes from the underlying random placement window, not from noise around a single value, and does not rule out a fixed due-date discrepancy as the cause.

**So what:** The stored `status` field cannot be trusted at face value for identifying genuinely delinquent accounts. More than half of what the raw data labels "late" payment behavior is actually within an acceptable grace window once verified independently against the documented 30-day rule. Relying on the stored label directly would overstate delinquency significantly and misdirect collections or portfolio-risk attention toward accounts that are not actually a problem. The specific mechanism here (two internal calculations of "due date" silently disagreeing by a fixed amount) is the same class of problem covered in SDG&E billing variance work: neither system throws an error, so the drift only surfaces when someone independently re-derives the field instead of trusting it.

**Recommendation:** Use the independently derived status, not the stored `status` field, for all downstream delinquency analysis in this project (AR aging buckets, revenue-at-risk, dashboard metrics). The derivation logic is validated by the failed-branch's perfect agreement and should be treated as the reliable source going forward.

**Limitation:** Root cause is fully diagnosed, not inferred. `generate_data.py` computes its internal due date as `period_start` plus one calendar month, 29 days earlier than the 30-days-after-period-end rule this check applies. Every late payment is placed 6-55 days after that internal due date; measured against the correct 30-day rule, the ones landing within 29 days early cross back into the on-time window, which is exactly the 29,768-row, -23-to-+5-day pattern above. This is a synthetic-data generation artifact -- two internal calculations of "due date" disagreeing by a fixed amount -- not a real-world delinquency behavior being modeled. Worth stating as diagnosed rather than open: tracing a mismatch to its exact mechanism, rather than stopping at "the label disagrees," is the stronger analytical signal.

### Missing / Underpaid Charges

**Business question:** Beyond the payment-status label, did every charge actually get paid in full -- and where it didn't, is that because no payment was ever recorded, or because a real payment attempt fell short?

**What the data shows:** Summing payments per charge (a charge could in principle receive more than one payment row, though none do in this dataset) and comparing the total against the charge's billed amount splits into two distinct groups: 4,324 charges have no payment row at all, and 8,534 have a payment record that didn't cover the full amount. These are not the same failure mode. Verified via a direct join rather than assumed from the matching count, the 8,534 underpaid charges are, without exception, the same 8,534 charges carrying a `status = 'failed'` payment row -- a real payment attempt was made and failed. The 4,324 no-payment charges never had a payment row built at all. That count lands close to the ~4,331 expected from the 6,187 duplicate charges flagged in the earlier duplicate-charge check, each with roughly a 30% chance in this dataset of receiving a payment record -- consistent with the same duplicate-charge population being the source, not a distinct new problem. Notably, `amount_paid` in this dataset is always either the full charge amount or exactly zero; no charge is ever partially paid, so "underpaid" and "had a failed payment attempt" collapse into one set here.

**So what:** Unlike check 1, this check doesn't touch the `status` field at all -- it's built directly from dollar amounts, so it carries none of check 1's "don't trust the label" caveat. The two shortfall types call for different operational responses, and lumping them into one "money owed" number would overstate real revenue at risk. A failed payment is a genuine collections problem on a bill that was correctly issued and attempted. A missing payment on a duplicate charge is a different kind of issue entirely -- duplicate charges are themselves the exception (per check 1), so the "real" charge for that account/period already exists and, per that same finding, is roughly 70% likely to already carry its own valid payment. The unpaid duplicate isn't necessarily uncollected revenue; it may just be an extra charge that was never going to get paid because it shouldn't have existed.

**Recommendation:** Carry this distinction forward into file 05's revenue-at-risk calculation rather than collapsing everything into one unpaid-charges figure. Treat the 8,534 failed-payment charges as a genuine collections target. Reconcile the 4,324 no-payment charges against the duplicate-charge population from check 1 before counting them as leakage -- a meaningful share are likely an already-paid charge's uncollected duplicate, not new revenue at risk.

**Limitation:** This check establishes what happened -- paid in full, paid $0 via a failed attempt, or never billed a payment attempt at all -- but not why a given payment failed, and it can't see whether any of the 4,324 no-payment duplicate charges were reversed or voided outside the `payments` table; a reversal like that isn't represented anywhere in this schema.

### AR Aging by Property and Utility Type

**Business question:** Of the charges that are currently unpaid, how is that outstanding balance distributed by how overdue it is, and where does it concentrate?

**What the data shows:** Restricted to the 12,858 outstanding charges already identified in the missing/underpaid check above (a charge that was eventually paid, on-time or late, carries a $0 balance as of the snapshot date and has no place in an aging-of-receivables view), each charge's due date is recomputed directly from its billing period and measured against a snapshot date of 2026-11-25, the dataset's latest recorded payment date. At the portfolio level: 0-30 days past due = 1,065 charges / $53,432.85; 31-60 = 1,066 / $52,525.62; 61-90 = 1,063 / $53,087.95; 90+ = 9,664 / $482,582.92. Roughly 75% of both outstanding charges and outstanding dollars sit in the 90+ bucket.

That concentration is not evidence of worsening collections performance. Grouping the same outstanding population by billing period instead of aging bucket shows a flat distribution: every one of the 12 months lands between 1,034 and 1,114 outstanding charges, no upward or downward trend across the year. The skew toward 90+ is mechanical, not behavioral: the snapshot date sits near the end of the dataset's fixed 12-month window, so only the three most recent billing periods (July-September 2026) can possibly still read as younger than 90 days past due at that snapshot. Every outstanding charge from the first nine months of the window is already past 90 days by construction, regardless of whether the underlying exception rate was flat, improving, or worsening month to month.

**So what:** Read at face value, "75% of overdue dollars are 90+ days past due" reads like a portfolio approaching crisis. Read correctly, it says nothing about trend at all -- it's an artifact of measuring a bounded historical window from a single point near its end, not a signal that delinquency is accelerating. A report that presented the bucket totals without checking what's driving them would draw exactly the wrong conclusion. This is the same category of caution as check 1's due-date finding: a headline number that's technically accurate but needs its construction understood before it means what it appears to mean.

**Recommendation:** For the file 05 dashboard, present the aging buckets alongside the by-billing-period view that shows no trend, so a viewer sees the shape without concluding delinquency is worsening over time. The 1,861-row property/utility/bucket breakdown this check produces (not summarized here, since it's too granular to characterize by hand) is the right input for identifying which specific properties or utility types carry a disproportionate share of outstanding balances -- that's where a real intervention target would show up, as opposed to the portfolio-level rollup, which is dominated by the snapshot-timing effect described above.

**Limitation:** This check identifies where outstanding balances currently sit; it doesn't establish why a given property or utility type might carry more of the 90+ balance than another, since the property/utility cut of this same output hasn't been reviewed yet -- worth a targeted look in file 04 or 05 rather than assumed here. It also inherits check 1's 30-days-after-period-end due-date convention rather than the generator's own internal due date -- the documented, intentional choice throughout this file, not an oversight.
