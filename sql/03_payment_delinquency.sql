-- Property Billing & Payments Analytics -- payment delinquency
-- Detects and characterizes payment delinquency across charges and
-- payments: whether the stored payment status can be trusted at face
-- value, whether every charge actually received payment, and how
-- outstanding balances age by property and utility type.
-- Assumes 01_data_cleaning.sql and 02_billing_exceptions.sql have
-- already run.

USE property_billing_analytics;

-- ---------------------------------------------------------------------
-- 1. Payment status validation
-- ---------------------------------------------------------------------
-- Business rule: charges are due 30 days after the billing period ends
-- (LAST_DAY(billing_period) + 30, same convention used for the
-- proration overlap test in 02_billing_exceptions.sql). A payment is
-- on-time if made within 5 days after the due date, late if 6-60 days
-- past due, and failed if later than that or never made at all.
-- failed rows carry a NULL payment_date by design (confirmed
-- empirically: all 8,534 failed-status payments have no payment_date),
-- so that branch is checked first rather than relying on a DATEDIFF
-- comparison that would just silently return NULL.
-- The status label stored on each payment row is independently
-- re-derived here and compared against it -- same "don't trust the
-- label" approach used for charge_type = 'prorated' in the proration
-- check above.
WITH due_dates AS (
    SELECT
        p.payment_id,
        p.charge_id,
        p.payment_date,
        p.status,
        LAST_DAY(c.billing_period) + INTERVAL 30 DAY AS due_date
    FROM payments p
    JOIN charges c ON p.charge_id = c.charge_id
),
status_check AS (
    SELECT
        payment_id,
        charge_id,
        payment_date,
        due_date,
        status AS stored_status,
        CASE
            WHEN payment_date IS NULL THEN 'failed'
            WHEN payment_date <= due_date + INTERVAL 5 DAY THEN 'on-time'
            WHEN payment_date <= due_date + INTERVAL 60 DAY THEN 'late'
            ELSE 'failed'
        END AS derived_status
    FROM due_dates
)
SELECT *
FROM status_check
WHERE stored_status <> derived_status
ORDER BY charge_id;
-- Result: 29,768 of 319,325 payment rows (9.3%) disagree. 100% of
-- mismatches run one direction -- stored 'late', derived 'on-time' --
-- with zero cases of the reverse. That's 58% of all 51,257 late-
-- labeled payments. The failed branch has zero disagreement across
-- all 8,534 failed rows, validating the due-date derivation and NULL-
-- handling; the mismatch is isolated to the on-time/late boundary.
-- Days-from-due-date within the mismatched rows spans -23 to +5
-- (stddev 8.4).
-- Root cause (confirmed against generate_data.py): the generator's
-- own internal due date is period_start + 1 calendar month, 29 days
-- earlier than the 30-days-after-period-end rule applied above. Late
-- payments are placed uniformly at random 6-55 days after that
-- internal due date, so re-measured against this query's due date
-- the spread becomes a uniform -23 to +26 days -- a fixed 29-day
-- due-date discrepancy interacting with an already-random placement
-- window, not evidence against a fixed offset.
-- See FINDINGS.md for the full write-up.

-- ---------------------------------------------------------------------
-- 2. Missing / underpaid charges
-- ---------------------------------------------------------------------
-- For every charge, does it have a payment row at all, and if so, did
-- the total collected across that charge's payment(s) reach the full
-- billed amount? Payments are summed per charge_id first (a charge
-- could in principle have more than one payment row, though in this
-- dataset it never does), keeping the grain at one row per charge
-- rather than one row per payment.
-- A charge with zero payment rows is distinguished from a charge with
-- a payment row that collected $0 (a failed attempt): the former never
-- got a payment record built at all (LEFT JOIN + IS NULL on the parent
-- table's key, same anti-join pattern used for the orphaned-FK checks
-- in 01_data_cleaning.sql), the latter had a real payment attempt that
-- came up short. This check works directly off dollar amounts, not
-- the stored status field, so it doesn't carry check 1's "don't trust
-- the label" caveat.
WITH payment_totals AS (
    SELECT charge_id, SUM(amount_paid) AS total_paid
    FROM payments
    GROUP BY charge_id
)
SELECT
    c.charge_id,
    c.amount AS charge_amount,
    COALESCE(pt.total_paid, 0) AS total_paid,
    CASE
        WHEN pt.charge_id IS NULL THEN 'no payment'
        WHEN pt.total_paid < c.amount THEN 'underpaid'
        ELSE 'fully paid'
    END AS payment_result
FROM charges c
LEFT JOIN payment_totals pt
    ON c.charge_id = pt.charge_id
WHERE pt.charge_id IS NULL
   OR pt.total_paid < c.amount;
-- Result: 12,858 charges have a payment shortfall -- 8,534 'underpaid'
-- and 4,324 'no payment'. Verified via a direct join (not assumed from
-- the matching count): all 8,534 underpaid charges carry a payment row
-- with status = 'failed', and none carry any other status. No charge
-- in this dataset is ever partially paid -- amount_paid is always
-- either the full charge amount or exactly 0 -- so 'underpaid' and
-- 'had a failed payment attempt' are the same set here. The 4,324
-- no-payment charges land close to the ~4,331 expected from the 6,187
-- injected duplicate charges flagged in check 1 above, each with
-- roughly a 30% chance of receiving a payment row -- consistent with
-- duplicates being the source, not a distinct new failure mode.
-- See FINDINGS.md for the full write-up.

-- ---------------------------------------------------------------------
-- 3. AR aging summary by property and utility type
-- ---------------------------------------------------------------------
-- Scope: outstanding charges only -- the same 12,858-charge population
-- as check 2's 'underpaid' + 'no payment' groups. A charge that was
-- paid, on-time or late, has a $0 balance as of the snapshot date and
-- doesn't belong in an aging-of-receivables view. due_date is
-- recomputed directly from charges.billing_period (same 30-day rule
-- as check 1) rather than reused from check 1's CTEs, since those were
-- built with an inner join to payments and would silently drop the
-- no-payment charges that have no payment row to join against.
-- Snapshot date 2026-11-25 = MAX(payment_date) across the dataset.
-- Outstanding dollars are calculated generally as amount - total_paid
-- rather than assumed equal to amount, even though in this dataset
-- total_paid is always 0 for this population (every outstanding
-- charge is either a failed $0 payment attempt or has no payment row
-- at all -- established in check 2).
WITH payment_totals AS (
    SELECT charge_id, SUM(amount_paid) AS total_paid
    FROM payments
    GROUP BY charge_id
),
outstanding_charges AS (
    SELECT
        c.charge_id,
        c.amount AS charge_amount,
        COALESCE(pt.total_paid, 0) AS total_paid,
        DATEDIFF(
            '2026-11-25',
            LAST_DAY(c.billing_period) + INTERVAL 30 DAY
        ) AS days_past_due,
        pr.property_id,
        pr.name AS property_name,
        ua.utility_type
    FROM charges c
    LEFT JOIN payment_totals pt
        ON c.charge_id = pt.charge_id
    JOIN utility_accounts ua
        ON c.account_id = ua.account_id
    JOIN units u
        ON ua.unit_id = u.unit_id
    JOIN properties pr
        ON u.property_id = pr.property_id
    WHERE pt.charge_id IS NULL
       OR pt.total_paid < c.amount
)
SELECT
    property_id,
    property_name,
    utility_type,
    CASE
        WHEN days_past_due BETWEEN 0 AND 30 THEN '0-30'
        WHEN days_past_due BETWEEN 31 AND 60 THEN '31-60'
        WHEN days_past_due BETWEEN 61 AND 90 THEN '61-90'
        WHEN days_past_due > 90 THEN '90+'
        ELSE 'check'
    END AS aging_bucket,
    COUNT(*) AS charge_count,
    SUM(charge_amount - total_paid) AS total_outstanding
FROM outstanding_charges
GROUP BY property_id, property_name, utility_type, aging_bucket
ORDER BY property_id, utility_type, aging_bucket;
-- Result: 1,861 property x utility_type x bucket rows. charge_count
-- sums to exactly 12,858 (reconciles to check 2's outstanding total),
-- and zero rows land in the 'check' catch-all bucket.
-- Portfolio-level totals (same query, property/utility joins dropped,
-- grouped by aging_bucket alone): 0-30 = 1,065 charges / $53,432.85;
-- 31-60 = 1,066 / $52,525.62; 61-90 = 1,063 / $53,087.95; 90+ = 9,664
-- / $482,582.92 -- roughly 75% of outstanding charges and dollars in
-- the 90+ bucket.
-- That concentration is a snapshot-timing artifact of the dataset's
-- fixed 12-month window, not evidence of worsening delinquency --
-- confirmed by grouping the same outstanding population by
-- billing_period instead of aging bucket: all 12 months land within
-- 1,034-1,114 outstanding charges, no trend. Because the snapshot date
-- (2026-11-25) sits near the end of the window, only the three most
-- recent billing periods (Jul-Sep 2026) can age into anything younger
-- than 90 days past due at that snapshot; the other nine months are
-- mechanically already past 90 days regardless of the underlying
-- exception rate in any given month.
-- See FINDINGS.md for the full write-up.
