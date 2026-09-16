-- Property Billing & Payments Analytics -- billing exceptions
-- Detects duplicate charges, missing charges (billing gaps), and
-- proration errors via pure SQL against charges/payments -- there is
-- no pre-labeled billing_exceptions table; every exception type below
-- is derived from business logic, not looked up from an answer key.
-- Assumes 01_data_cleaning.sql has already confirmed structural
-- integrity of the loaded data.

USE property_billing_analytics;

-- ---------------------------------------------------------------------
-- 1. Duplicate charges
-- ---------------------------------------------------------------------
-- Grain: the same account_id + billing_period + charge_type + amount
-- combination should never appear more than once -- that would mean
-- the same billing event was charged twice. charge_type is included
-- in the grain deliberately: a usage charge and a late fee legitimately
-- posting in the same account+period is not a duplicate, and excluding
-- charge_type would have produced false positives on that case.
-- COUNT(*) OVER (PARTITION BY ...) computes each group's size in a
-- single pass; ROW_NUMBER() would not work here since it only assigns
-- sequential numbers within a partition and doesn't expose group size.
SELECT
    charge_id,
    account_id,
    billing_period,
    charge_type,
    amount,
    group_size
FROM (
    SELECT
        charge_id,
        account_id,
        billing_period,
        charge_type,
        amount,
        COUNT(*) OVER (
            PARTITION BY account_id, billing_period, charge_type, amount
        ) AS group_size
    FROM charges
) sized
WHERE group_size > 1
ORDER BY account_id, billing_period;
-- Result: 12,374 rows flagged -- matches the data profile's known
-- 6,187 injected duplicate account+billing_period combos x 2 exactly,
-- confirming the detection grain catches the intended duplicates
-- cleanly without pulling in unrelated multi-charge periods.

-- ---------------------------------------------------------------------
-- 2. Missing charges (billing gaps)
-- ---------------------------------------------------------------------
-- For every utility account, during every billing period its lease was
-- active, a charge should exist. Scaffold: CROSS JOIN each account
-- against the distinct billing_period values that actually occur
-- elsewhere in charges (a data-derived "calendar" rather than a
-- hardcoded one), restricted to periods that overlap that account's
-- lease coverage. Overlap uses the same month-level date-range test as
-- proration detection below (start1 <= end2 AND end1 >= start2) rather
-- than exact containment, so a lease starting or ending mid-month still
-- counts as expecting a charge for that month. Anti-joined (LEFT JOIN +
-- IS NULL on the parent/charges side) against actual charges to surface
-- combinations with no matching row.
WITH account_periods AS (
    SELECT DISTINCT
        ua.account_id,
        bp.billing_period
    FROM utility_accounts ua
    JOIN units u ON ua.unit_id = u.unit_id
    JOIN leases l ON u.unit_id = l.unit_id
    CROSS JOIN (SELECT DISTINCT billing_period FROM charges) bp
    WHERE bp.billing_period <= l.lease_end
      AND LAST_DAY(bp.billing_period) >= l.lease_start
)
SELECT
    ap.account_id,
    ap.billing_period
FROM account_periods ap
LEFT JOIN charges c
    ON ap.account_id = c.account_id
   AND ap.billing_period = c.billing_period
WHERE c.charge_id IS NULL
ORDER BY ap.account_id, ap.billing_period;
-- Result: 6,790 missing-charge instances across 5,770 of 27,124
-- utility accounts (about 21%). Spot-checked against accounts 6 and 9
-- in leases/charges directly: account 6 has continuous coverage and is
-- missing only February 2026; account 9 has continuous coverage and is
-- missing two consecutive months (April-May 2026), a real gap rather
-- than a lease-turnover false positive.

-- ---------------------------------------------------------------------
-- 3a. Proration errors -- amount/calculation check
-- ---------------------------------------------------------------------
-- Among charges already labeled 'prorated', does the billed amount
-- match expected_amount? Deliberately simple, no join -- this check is
-- independent of whether the 'prorated' label itself is correct (see
-- 3b), so it only asks "given this label, is the dollar amount right."
SELECT
    charge_id,
    account_id,
    billing_period,
    charge_type,
    amount,
    expected_amount
FROM charges
WHERE charge_type = 'prorated'
  AND amount <> expected_amount
ORDER BY billing_period, account_id;
-- Result: 5,105 of 9,537 prorated charges (53.5%) have a wrong amount.
-- This single category accounts for the entire portfolio-wide amount-
-- variance figure -- zero non-prorated charges have any variance, and
-- 5,105 / 323,649 = 1.58%, reconciling almost exactly with the data
-- profile's stated 1.6% baseline.

-- ---------------------------------------------------------------------
-- 3b. Proration errors -- classification check
-- ---------------------------------------------------------------------
-- Independent of the amount check above: does the label charge_type
-- match what the billing period's overlap with the lease's
-- lease_start/lease_end structurally implies it should be? Full-month
-- containment (billing_period >= lease_start AND LAST_DAY(billing_period)
-- <= lease_end) implies 'regular'; any partial overlap implies
-- 'prorated'. DISTINCT guards against a charge matching more than one
-- lease record (tenant-turnover edge case) inflating the result --
-- empirically verified via GROUP BY charge_id HAVING COUNT(*) > 1 on
-- this result set, which returns zero rows, confirming that edge case
-- does not occur in this dataset.
WITH classified AS (
    SELECT
        c.charge_id,
        c.account_id,
        c.billing_period,
        c.charge_type,
        CASE
            WHEN c.billing_period >= l.lease_start
             AND LAST_DAY(c.billing_period) <= l.lease_end
                THEN 'regular'
            ELSE 'prorated'
        END AS expected_charge_type,
        l.lease_start,
        l.lease_end
    FROM charges c
    JOIN utility_accounts ua ON c.account_id = ua.account_id
    JOIN units u ON ua.unit_id = u.unit_id
    JOIN leases l ON u.unit_id = l.unit_id
    WHERE c.billing_period <= l.lease_end
      AND LAST_DAY(c.billing_period) >= l.lease_start
)
SELECT DISTINCT
    charge_id, account_id, billing_period, charge_type,
    expected_charge_type, lease_start, lease_end
FROM classified
WHERE charge_type <> expected_charge_type
ORDER BY billing_period, account_id;
-- Result: 2,254 rows -- 0.70% of all charges. Entirely one-directional:
-- every mismatch is charge_type = 'prorated' with expected_charge_type
-- = 'regular' (confirmed via a separate breakdown query), never the
-- reverse. All 2,254 of these charges are also a subset of the 5,105
-- amount-error charges from 3a -- every misclassified charge also has
-- a wrong amount (verified via a join between the two result sets).
-- Spot-checked charge 132 (mid-lease, no boundary nearby, yet labeled
-- prorated with a wrong amount) and charge 393 (a genuine tenant-
-- turnover boundary case, correctly labeled prorated, still overbilled)
-- against leases/charges directly -- see FINDINGS.md for the full
-- two-pattern breakdown (Pattern A: mislabeled, ratio range 0.50-1.80,
-- both directions; Pattern B: genuine boundary charges, always
-- overbilled, ratio range 1.03-31.2, worst on small-dollar charges).

-- ---------------------------------------------------------------------
-- Summary: three distinct exception types detected in charges, none
-- overlapping in mechanism -- 12,374 duplicate-charge rows, 6,790
-- missing-charge instances across 5,770 accounts, and 5,105 proration
-- amount errors (of which 2,254 are also mislabeled). Full narrative,
-- business impact, and recommendations for each are in FINDINGS.md.
-- Proceed to 03_payment_delinquency.sql.
