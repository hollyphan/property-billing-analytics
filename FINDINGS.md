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
