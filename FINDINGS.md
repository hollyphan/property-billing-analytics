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
