-- Property Billing & Payments Analytics -- portfolio variance trend
-- Trends billing exceptions at the portfolio level, month over month,
-- with total billed dollars and active accounts carried as context
-- rather than as the primary metric. Assumes 01_data_cleaning.sql,
-- 02_billing_exceptions.sql, and 03_payment_delinquency.sql have
-- already run.
-- Scope note: "exception" here means a charge flagged by either of the
-- two purely billing-side checks from file 02 -- duplicate (same
-- account_id + billing_period + charge_type + amount appearing more
-- than once) or proration/amount mismatch (amount <> expected_amount).
-- Payment-side delinquency from file 03 is a separate trend, out of
-- scope here since this file works from charges/utility_accounts/
-- leases only, not payments.

USE property_billing_analytics;

-- ---------------------------------------------------------------------
-- 1. Billing-period coverage check
-- ---------------------------------------------------------------------
-- Before trending anything month over month, confirm the 12 billing
-- periods in charges are complete and contiguous -- a silently missing
-- month would look identical to a real down month once LAG() runs on
-- it. month_gap is computed once here, in a dedicated CTE, rather than
-- inline in multiple places. DATEDIFF (not a fixed-month subtraction)
-- is deliberate: since billing_period is always the first of a month,
-- a genuinely contiguous sequence still returns a real 28-31 depending
-- on the prior month's actual length, so anything outside that range
-- -- not just anything <> 1 -- is the signal of a real gap.
WITH billing_months AS (
    SELECT DISTINCT billing_period FROM charges
),
month_sequence AS (
    SELECT
        billing_period,
        LAG(billing_period) OVER (ORDER BY billing_period) AS prior_period
    FROM billing_months
)
SELECT
    billing_period,
    prior_period,
    DATEDIFF(billing_period, prior_period) AS month_gap
FROM month_sequence
ORDER BY billing_period;
-- Result: 12 rows, Oct 2025 through Sep 2026, fully contiguous. First
-- row's prior_period/month_gap is NULL as expected; every other row's
-- month_gap falls in 28-31, matching each prior month's real length
-- exactly (31, 30, 31, 31, 28, 31, 30, 31, 30, 31, 31) -- no missing
-- or duplicated months. Coverage confirmed; safe to trust LAG()
-- comparisons in check 2 below as real month-over-month deltas.

-- ---------------------------------------------------------------------
-- 2. Portfolio exception trend
-- ---------------------------------------------------------------------
-- One row per month: total charges, total exceptions (see scope note
-- above), exception rate, total billed dollars, and active accounts,
-- each compared to the prior month via LAG(). Active accounts is
-- included specifically as a check against a false trend -- if
-- exceptions rise in step with active accounts, that's portfolio
-- growth, not worsening billing behavior; the exception rate (already
-- normalized by that month's charge volume) and the active_accounts
-- columns sitting side by side make that distinction visible directly
-- in the output rather than requiring a second query to catch it.
--
-- flagged_charges: per-charge exception flag, computed in its own CTE
-- since a window function can't sit inside an aggregate's CASE in the
-- same SELECT that GROUPs BY billing_period -- it has to be resolved
-- to a plain 0/1 column first, then summed. Duplicate detection reuses
-- file 02 check 1's grain exactly (COUNT(*) OVER partitioned by
-- account_id, billing_period, charge_type, amount -- charge_type and
-- amount are both in the partition deliberately, so a regular charge
-- and a prorated charge legitimately landing on the same account in
-- the same period, e.g. mid-month lease turnover, isn't miscounted as
-- a duplicate); proration/amount detection reuses file 02 check 3a's
-- test (amount <> expected_amount). A charge tripping both conditions
-- is still counted once (CASE returns a single 0/1 flag, not two), so
-- total_exceptions can't double-count a charge that's both duplicate
-- and mismatched.
--
-- active_accounts: correlated subquery per month rather than a
-- separate CROSS-JOIN CTE, since counting is cheap at 12 rows and
-- COUNT(DISTINCT ua.account_id) already collapses a unit with
-- overlapping leases (turnover mid-month) without a separate dedup
-- step. Overlap test is the same one used throughout this project
-- (lease_start <= LAST_DAY(billing_period) AND lease_end >=
-- billing_period), just with the lease bounds on the left instead of
-- the billing_period bounds -- equivalent, not a different test.
--
-- with_lags: LAG() computed once per metric here and referenced
-- downstream in the final SELECT for the change_ columns, rather than
-- re-invoked per derived column (same fix applied to a repeated
-- DATEDIFF in file 03's AR aging check).
WITH flagged_charges AS (
    SELECT
        charge_id,
        account_id,
        billing_period,
        amount,
        CASE
            WHEN amount <> expected_amount
                 OR COUNT(*) OVER (
                        PARTITION BY account_id, billing_period, charge_type, amount
                    ) > 1
            THEN 1 ELSE 0
        END AS is_exception
    FROM charges
),
monthly_charges AS (
    SELECT
        billing_period,
        COUNT(*) AS total_charges,
        SUM(is_exception) AS total_exceptions,
        SUM(amount) AS total_billed_dollars
    FROM flagged_charges
    GROUP BY billing_period
),
monthly_metrics AS (
    SELECT
        mc.billing_period,
        mc.total_charges,
        mc.total_exceptions,
        ROUND(mc.total_exceptions * 100.0 / mc.total_charges, 2) AS exception_rate_pct,
        mc.total_billed_dollars,
        (
            SELECT COUNT(DISTINCT ua.account_id)
            FROM utility_accounts ua
            JOIN units u ON ua.unit_id = u.unit_id
            JOIN leases l ON u.unit_id = l.unit_id
            WHERE l.lease_start <= LAST_DAY(mc.billing_period)
              AND l.lease_end >= mc.billing_period
        ) AS active_accounts
    FROM monthly_charges mc
),
with_lags AS (
    SELECT
        billing_period,
        total_charges,
        total_exceptions,
        exception_rate_pct,
        total_billed_dollars,
        active_accounts,
        LAG(total_charges) OVER (ORDER BY billing_period) AS prior_total_charges,
        LAG(total_exceptions) OVER (ORDER BY billing_period) AS prior_total_exceptions,
        LAG(exception_rate_pct) OVER (ORDER BY billing_period) AS prior_exception_rate_pct,
        LAG(total_billed_dollars) OVER (ORDER BY billing_period) AS prior_total_billed_dollars,
        LAG(active_accounts) OVER (ORDER BY billing_period) AS prior_active_accounts
    FROM monthly_metrics
)
SELECT
    billing_period,

    total_charges,
    prior_total_charges,
    total_charges - prior_total_charges AS change_total_charges,

    total_exceptions,
    prior_total_exceptions,
    total_exceptions - prior_total_exceptions AS change_total_exceptions,

    exception_rate_pct,
    prior_exception_rate_pct,
    exception_rate_pct - prior_exception_rate_pct AS change_exception_rate_pct,

    total_billed_dollars,
    prior_total_billed_dollars,
    total_billed_dollars - prior_total_billed_dollars AS change_total_billed_dollars,

    active_accounts,
    prior_active_accounts,
    active_accounts - prior_active_accounts AS change_active_accounts

FROM with_lags
ORDER BY billing_period;
-- Result: [pending -- run in terminal, paste back the full 12-row
-- output. First row's prior_*/change_* columns should be NULL, not 0
-- or an error -- that's the intended "no prior period" state, not a
-- bug.]
