-- Property Billing & Payments Analytics -- revenue at risk summary
-- Rolls up the exception and delinquency findings from files 02-04
-- into a property-level view of where revenue leakage concentrates.
-- No new detection logic -- every component reuses a grain already
-- established and validated in an earlier file. Assumes
-- 01_data_cleaning.sql, 02_billing_exceptions.sql,
-- 03_payment_delinquency.sql, and 04_portfolio_variance_trend.sql
-- have already run.

USE property_billing_analytics;

-- ---------------------------------------------------------------------
-- 1. Revenue at risk by property
-- ---------------------------------------------------------------------
-- Three exposure components, each aggregated down to one row per
-- property_id independently before being joined together -- joining
-- the underlying charge-level populations directly first would create
-- a many-to-many fan-out and silently inflate every total.
--
-- outstanding_ar: file 03 check 2's shortfall population (no payment,
-- or a payment that didn't cover the full amount), summed by property.
--
-- duplicate_exposure: file 02 check 1's exact grain (account_id,
-- billing_period, charge_type, amount). Unlike file 02, this doesn't
-- need a window function -- file 02 needed COUNT(*) OVER (PARTITION
-- BY ...) because it returned every individual flagged charge row;
-- here we only need each group's size, which a plain GROUP BY ...
-- HAVING COUNT(*) > 1 gives directly. Summing every flagged charge's
-- amount would double-count, since a duplicate group's members are
-- identical charges by construction (amount is part of the group-by)
-- -- only (group_size - 1) charges per group are the "extra" ones
-- actually at risk.
--
-- amount_mismatch_exposure: file 02 check 3a's test (amount <>
-- expected_amount), not charge_type = 'prorated' -- that label is
-- unreliable (file 02's Pattern A). The dollar figure is ABS(amount -
-- expected_amount), the size of the error itself, not the full charge
-- amount -- using the full amount would let Pattern B's small-dollar,
-- up-to-31x-overbilled charges misrepresent a large error as a large
-- exposure.
--
-- total_exposure here is the naive sum of all three. Check 2 below
-- reconciles a known overlap between two of these components before
-- this number gets treated as a final figure.
WITH payment_totals AS (
    SELECT charge_id, SUM(amount_paid) AS total_paid
    FROM payments
    GROUP BY charge_id
),
shortfall_charges AS (
    SELECT
        c.charge_id,
        c.account_id,
        c.amount - COALESCE(pt.total_paid, 0) AS outstanding_amount
    FROM charges c
    LEFT JOIN payment_totals pt
        ON c.charge_id = pt.charge_id
    WHERE pt.charge_id IS NULL
       OR pt.total_paid < c.amount
),
ar_by_property AS (
    SELECT
        u.property_id,
        SUM(sc.outstanding_amount) AS outstanding_ar
    FROM shortfall_charges sc
    JOIN utility_accounts ua ON sc.account_id = ua.account_id
    JOIN units u ON ua.unit_id = u.unit_id
    GROUP BY u.property_id
),
duplicate_groups AS (
    SELECT
        account_id,
        billing_period,
        charge_type,
        amount,
        COUNT(*) AS group_size
    FROM charges
    GROUP BY account_id, billing_period, charge_type, amount
    HAVING COUNT(*) > 1
),
duplicate_exposure_by_property AS (
    SELECT
        u.property_id,
        SUM((dg.group_size - 1) * dg.amount) AS duplicate_exposure
    FROM duplicate_groups dg
    JOIN utility_accounts ua ON dg.account_id = ua.account_id
    JOIN units u ON ua.unit_id = u.unit_id
    GROUP BY u.property_id
),
mismatch_charges AS (
    SELECT
        charge_id,
        account_id,
        ABS(amount - expected_amount) AS mismatch_amount
    FROM charges
    WHERE amount <> expected_amount
),
mismatch_exposure_by_property AS (
    SELECT
        u.property_id,
        SUM(mc.mismatch_amount) AS amount_mismatch_exposure
    FROM mismatch_charges mc
    JOIN utility_accounts ua ON mc.account_id = ua.account_id
    JOIN units u ON ua.unit_id = u.unit_id
    GROUP BY u.property_id
)
SELECT
    p.property_id,
    p.name,
    p.market,
    p.unit_count,
    COALESCE(ar.outstanding_ar, 0) AS outstanding_ar,
    COALESCE(de.duplicate_exposure, 0) AS duplicate_exposure,
    COALESCE(me.amount_mismatch_exposure, 0) AS amount_mismatch_exposure,
    COALESCE(ar.outstanding_ar, 0)
        + COALESCE(de.duplicate_exposure, 0)
        + COALESCE(me.amount_mismatch_exposure, 0) AS total_exposure
FROM properties p
LEFT JOIN ar_by_property ar
    ON p.property_id = ar.property_id
LEFT JOIN duplicate_exposure_by_property de
    ON p.property_id = de.property_id
LEFT JOIN mismatch_exposure_by_property me
    ON p.property_id = me.property_id
ORDER BY total_exposure DESC;
-- Result: 150 rows, one per property. Reconciles exactly against
-- prior files: SUM(outstanding_ar) = $641,629.34, matching file 03's
-- four aging buckets summed exactly (53,432.85 + 52,525.62 + 53,087.95
-- + 482,582.92). SUM(duplicate_exposure) = $307,212.82 and
-- SUM(amount_mismatch_exposure) = $134,136.08 are new dollar figures
-- -- file 02 only ever reported counts (6,187 groups, 5,105 charges),
-- never summed dollars. Grand total (naive) = $1,082,978.24.
-- Sorted by total_exposure, a sharp cliff separates the top 27
-- properties ($11,300-$26,197) from the remaining 123 ($2,323-
-- $6,752) -- 27 of 150 is exactly 18%, the seeded elevated-exception
-- population referenced since file 01. Not a size artifact: property
-- 36 (rank 1, 58 units) runs ~$452/unit; property 93 (rank 28, 57
-- units -- nearly identical size) runs ~$118/unit, about a quarter as
-- much. See check 2 below before treating this total as final.

-- ---------------------------------------------------------------------
-- 2. Duplicate / outstanding-AR overlap reconciliation
-- ---------------------------------------------------------------------
-- File 03's FINDINGS.md flagged this explicitly as something to carry
-- into file 05: some of the 4,324 no-payment charges (check 2) are the
-- unpaid half of a duplicate pair (check 1) -- an extra charge that
-- was never going to get paid because it shouldn't have existed, not
-- new uncollected revenue on top of what check 1 already counts. If
-- both check 1's outstanding_ar and duplicate_exposure count that same
-- dollar amount, total_exposure above overstates real risk.
--
-- A duplicate group's "extra" dollar claim (one unit, per check 1)
-- overlaps with outstanding_ar whenever at least one charge in that
-- group has no payment. That's true whether one or both of the pair
-- went unpaid -- duplicate_exposure only ever claims one unit of
-- exposure per group, so at most one unit can overlap regardless of
-- how many of the two charges are actually unpaid. CASE WHEN
-- unpaid_in_group >= 1 THEN amount ELSE 0 enforces that cap directly,
-- rather than something like unpaid_in_group * amount, which would
-- overstate the overlap past what check 1 even claimed.
WITH payment_totals AS (
    SELECT charge_id, SUM(amount_paid) AS total_paid
    FROM payments
    GROUP BY charge_id
),
duplicate_groups AS (
    SELECT
        c.account_id,
        c.billing_period,
        c.charge_type,
        c.amount,
        SUM(CASE WHEN COALESCE(pt.total_paid, 0) = 0 THEN 1 ELSE 0 END) AS unpaid_in_group
    FROM charges c
    LEFT JOIN payment_totals pt
        ON c.charge_id = pt.charge_id
    GROUP BY c.account_id, c.billing_period, c.charge_type, c.amount
    HAVING COUNT(*) > 1
)
SELECT
    u.property_id,
    SUM(CASE WHEN dg.unpaid_in_group >= 1 THEN dg.amount ELSE 0 END) AS duplicate_ar_overlap
FROM duplicate_groups dg
JOIN utility_accounts ua ON dg.account_id = ua.account_id
JOIN units u ON ua.unit_id = u.unit_id
GROUP BY u.property_id
ORDER BY duplicate_ar_overlap DESC;
-- Result: SUM(duplicate_ar_overlap) = $218,473.58 across 150
-- properties -- 71.1% of check 1's $307,212.82 duplicate_exposure
-- total, meaning most duplicate groups have at least one unpaid
-- charge in them. This closely matches file 03's independent estimate
-- that each duplicate charge has roughly a 30% chance of receiving a
-- payment record (i.e., ~70% chance of landing in the unpaid
-- population check 1 already counts) -- two separate checks arriving
-- at essentially the same overlap rate from different angles.
-- Reconciled grand total = $1,082,978.24 - $218,473.58 = $864,504.66.
-- The property-level cliff from check 1 survives this adjustment:
-- rank 27 (property 115, adjusted ~$9,526) still sits well clear of
-- rank 28 (property 93, adjusted ~$4,911) -- the ~18% elevated
-- population isn't an artifact of the unadjusted total.

-- ---------------------------------------------------------------------
-- 3. Revenue at risk normalized by property size
-- ---------------------------------------------------------------------
-- Check 1 showed a cliff separating the top 27 properties from the
-- rest, and one spot-check (property 36 vs. property 93 -- nearly
-- identical unit_count, very different exposure) suggested it wasn't
-- just a size effect. This check makes that comparison for all 150
-- properties instead of one pair, by dividing each property's
-- reconciled exposure (check 1's three components minus check 2's
-- overlap) by its unit_count.
--
-- combined_exposure_by_property reuses check 1's and check 2's CTEs
-- verbatim (ar_by_property, duplicate_exposure_by_property -- now also
-- carrying duplicate_ar_overlap, mismatch_exposure_by_property) and
-- combines them into the single total_exposure_adjusted figure once,
-- in its own CTE -- the same "derive once, reference downstream"
-- principle already used throughout this project (file 03's AR aging
-- DATEDIFF, file 04's LAG() columns), so the expression isn't written
-- out twice between this CTE and the final SELECT.
--
-- unit_count is never 0 in this dataset (observed range 30-60 across
-- all 150 properties), so exposure_per_unit needs no divide-by-zero
-- guard.
--
-- What to look for: does the ranking by exposure_per_unit still put
-- roughly the same properties on top, or does a smaller property that
-- didn't make check 1's raw-dollar top 27 turn out to have a worse
-- per-unit rate once size stops hiding it?
WITH payment_totals AS (
    SELECT charge_id, SUM(amount_paid) AS total_paid
    FROM payments
    GROUP BY charge_id
),
shortfall_charges AS (
    SELECT
        c.charge_id,
        c.account_id,
        c.amount - COALESCE(pt.total_paid, 0) AS outstanding_amount
    FROM charges c
    LEFT JOIN payment_totals pt
        ON c.charge_id = pt.charge_id
    WHERE pt.charge_id IS NULL
       OR pt.total_paid < c.amount
),
ar_by_property AS (
    SELECT
        u.property_id,
        SUM(sc.outstanding_amount) AS outstanding_ar
    FROM shortfall_charges sc
    JOIN utility_accounts ua ON sc.account_id = ua.account_id
    JOIN units u ON ua.unit_id = u.unit_id
    GROUP BY u.property_id
),
duplicate_groups AS (
    SELECT
        c.account_id,
        c.billing_period,
        c.charge_type,
        c.amount,
        COUNT(*) AS group_size,
        SUM(CASE WHEN COALESCE(pt.total_paid, 0) = 0 THEN 1 ELSE 0 END) AS unpaid_in_group
    FROM charges c
    LEFT JOIN payment_totals pt
        ON c.charge_id = pt.charge_id
    GROUP BY c.account_id, c.billing_period, c.charge_type, c.amount
    HAVING COUNT(*) > 1
),
duplicate_exposure_by_property AS (
    SELECT
        u.property_id,
        SUM((dg.group_size - 1) * dg.amount) AS duplicate_exposure,
        SUM(CASE WHEN dg.unpaid_in_group >= 1 THEN dg.amount ELSE 0 END) AS duplicate_ar_overlap
    FROM duplicate_groups dg
    JOIN utility_accounts ua ON dg.account_id = ua.account_id
    JOIN units u ON ua.unit_id = u.unit_id
    GROUP BY u.property_id
),
mismatch_charges AS (
    SELECT
        charge_id,
        account_id,
        ABS(amount - expected_amount) AS mismatch_amount
    FROM charges
    WHERE amount <> expected_amount
),
mismatch_exposure_by_property AS (
    SELECT
        u.property_id,
        SUM(mc.mismatch_amount) AS amount_mismatch_exposure
    FROM mismatch_charges mc
    JOIN utility_accounts ua ON mc.account_id = ua.account_id
    JOIN units u ON ua.unit_id = u.unit_id
    GROUP BY u.property_id
),
combined_exposure_by_property AS (
    SELECT
        p.property_id,
        p.name,
        p.market,
        p.unit_count,
        COALESCE(ar.outstanding_ar, 0)
            + COALESCE(de.duplicate_exposure, 0)
            + COALESCE(me.amount_mismatch_exposure, 0)
            - COALESCE(de.duplicate_ar_overlap, 0) AS total_exposure_adjusted
    FROM properties p
    LEFT JOIN ar_by_property ar
        ON p.property_id = ar.property_id
    LEFT JOIN duplicate_exposure_by_property de
        ON p.property_id = de.property_id
    LEFT JOIN mismatch_exposure_by_property me
        ON p.property_id = me.property_id
)
SELECT
    property_id,
    name,
    market,
    unit_count,
    total_exposure_adjusted,
    ROUND(total_exposure_adjusted / unit_count, 2) AS exposure_per_unit
FROM combined_exposure_by_property
ORDER BY exposure_per_unit DESC;
-- Result: sorted by exposure_per_unit, the same cliff appears again
-- -- and it's the exact same 27 properties as check 1's raw-dollar
-- top 27, just reordered (smaller properties like 29, 109, and 130
-- move up once size stops diluting their rate -- property 29 jumps
-- from raw rank 21 to per-unit rank 1 -- while larger ones like 36
-- and 8 drop a few spots but stay in the group). Sorted numerically,
-- check 1's top-27 property_id set and this check's top-27 set are
-- identical. The cliff is sharper normalized than raw: rank 27
-- (property 56, $280.37/unit) to rank 28 (property 85, $113.37/unit)
-- is roughly a 2.5x drop, versus roughly 1.7x in check 1's raw
-- dollars ($11,300 to $6,752). This confirms check 1's finding rather
-- than contradicting it -- the ~18% elevated population is a
-- genuinely distinct group, not an artifact of which properties
-- happen to be bigger.

-- ---------------------------------------------------------------------
-- 4. Revenue at risk by utility type
-- ---------------------------------------------------------------------
-- Same three exposure components and overlap correction as checks
-- 1-2, regrouped by utility_type instead of property_id -- no new
-- detection logic, just a different GROUP BY target on the same CTEs.
-- With only 4 utility types (water/electric/gas/trash), a normalized
-- per-account rate isn't as necessary as it was across 150 properties
-- in check 3 -- total_accounts is included as a plain context column
-- instead, so a reader can see whether one type's raw dollar total is
-- explained by it simply having more accounts, without needing a
-- computed rate column to do it.
--
-- account_counts is the base table here (LEFT JOIN target for the
-- other three), the same role properties played in checks 1 and 3 --
-- every utility_type should appear even if, hypothetically, one had
-- zero exposure in some component.
WITH payment_totals AS (
    SELECT charge_id, SUM(amount_paid) AS total_paid
    FROM payments
    GROUP BY charge_id
),
shortfall_charges AS (
    SELECT
        c.charge_id,
        c.account_id,
        c.amount - COALESCE(pt.total_paid, 0) AS outstanding_amount
    FROM charges c
    LEFT JOIN payment_totals pt
        ON c.charge_id = pt.charge_id
    WHERE pt.charge_id IS NULL
       OR pt.total_paid < c.amount
),
ar_by_utility AS (
    SELECT
        ua.utility_type,
        SUM(sc.outstanding_amount) AS outstanding_ar
    FROM shortfall_charges sc
    JOIN utility_accounts ua ON sc.account_id = ua.account_id
    GROUP BY ua.utility_type
),
duplicate_groups AS (
    SELECT
        c.account_id,
        c.billing_period,
        c.charge_type,
        c.amount,
        COUNT(*) AS group_size,
        SUM(CASE WHEN COALESCE(pt.total_paid, 0) = 0 THEN 1 ELSE 0 END) AS unpaid_in_group
    FROM charges c
    LEFT JOIN payment_totals pt
        ON c.charge_id = pt.charge_id
    GROUP BY c.account_id, c.billing_period, c.charge_type, c.amount
    HAVING COUNT(*) > 1
),
duplicate_exposure_by_utility AS (
    SELECT
        ua.utility_type,
        SUM((dg.group_size - 1) * dg.amount) AS duplicate_exposure,
        SUM(CASE WHEN dg.unpaid_in_group >= 1 THEN dg.amount ELSE 0 END) AS duplicate_ar_overlap
    FROM duplicate_groups dg
    JOIN utility_accounts ua ON dg.account_id = ua.account_id
    GROUP BY ua.utility_type
),
mismatch_charges AS (
    SELECT
        charge_id,
        account_id,
        ABS(amount - expected_amount) AS mismatch_amount
    FROM charges
    WHERE amount <> expected_amount
),
mismatch_exposure_by_utility AS (
    SELECT
        ua.utility_type,
        SUM(mc.mismatch_amount) AS amount_mismatch_exposure
    FROM mismatch_charges mc
    JOIN utility_accounts ua ON mc.account_id = ua.account_id
    GROUP BY ua.utility_type
),
account_counts AS (
    SELECT utility_type, COUNT(*) AS total_accounts
    FROM utility_accounts
    GROUP BY utility_type
)
SELECT
    ac.utility_type,
    ac.total_accounts,
    COALESCE(ar.outstanding_ar, 0) AS outstanding_ar,
    COALESCE(de.duplicate_exposure, 0) AS duplicate_exposure,
    COALESCE(de.duplicate_ar_overlap, 0) AS duplicate_ar_overlap,
    COALESCE(me.amount_mismatch_exposure, 0) AS amount_mismatch_exposure,
    COALESCE(ar.outstanding_ar, 0)
        + COALESCE(de.duplicate_exposure, 0)
        + COALESCE(me.amount_mismatch_exposure, 0)
        - COALESCE(de.duplicate_ar_overlap, 0) AS total_exposure_adjusted
FROM account_counts ac
LEFT JOIN ar_by_utility ar
    ON ac.utility_type = ar.utility_type
LEFT JOIN duplicate_exposure_by_utility de
    ON ac.utility_type = de.utility_type
LEFT JOIN mismatch_exposure_by_utility me
    ON ac.utility_type = me.utility_type
ORDER BY total_exposure_adjusted DESC;
-- Result: 4 rows. total_exposure_adjusted sums to exactly $864,504.66
-- (electric $378,602.50 + water $201,390.27 + gas $174,139.63 + trash
-- $110,372.26), matching check 2's reconciled grand total exactly --
-- confirms this is the same population regrouped, not a new one.
-- total_accounts = 6,781 for all four types (one account per unit per
-- utility type, 6,781 x 4 = 27,124, file 01's known total).
-- Ranking is electric > water > gas > trash in every component
-- (outstanding_ar, duplicate_exposure, amount_mismatch_exposure), and
-- the ratios relative to electric are nearly identical across all
-- three components (water ~0.53, gas ~0.46, trash ~0.29 in each) --
-- the same signature file 04 used to catch a volume-mix effect rather
-- than a genuine behavioral difference. See check 5 before concluding
-- electric billing is actually worse-managed than the other three
-- types.

-- ---------------------------------------------------------------------
-- 5. Revenue at risk as a percentage of billed dollars, by utility type
-- ---------------------------------------------------------------------
-- Check 4's raw-dollar ranking (electric > water > gas > trash) had
-- nearly identical ratios across all three exposure components, which
-- looks like a bill-size effect rather than a real behavioral
-- difference -- electric bills likely just cost more per charge than
-- trash. This check settles it: exposure as a percentage of each
-- type's total billed dollar volume, not raw dollars. If electric's
-- rate comes out close to the other three, check 4's ranking was a
-- size artifact. If it comes out meaningfully higher even as a rate,
-- electric genuinely has worse billing/collections behavior, not just
-- bigger bills.
--
-- billed_dollars_by_utility sums charges.amount (not expected_amount)
-- by utility_type -- the actual dollar volume billed, which is the
-- right denominator for "what fraction of what we billed is at risk,"
-- as opposed to expected_amount, which would understate the
-- denominator for the exact overbilled charges check 4 is trying to
-- rate.
--
-- combined_exposure_by_utility follows the same "derive once,
-- reference downstream" pattern as check 3 and check 4 -- 
-- total_exposure_adjusted is computed a single time here rather than
-- repeated in the final SELECT.
WITH payment_totals AS (
    SELECT charge_id, SUM(amount_paid) AS total_paid
    FROM payments
    GROUP BY charge_id
),
shortfall_charges AS (
    SELECT
        c.charge_id,
        c.account_id,
        c.amount - COALESCE(pt.total_paid, 0) AS outstanding_amount
    FROM charges c
    LEFT JOIN payment_totals pt
        ON c.charge_id = pt.charge_id
    WHERE pt.charge_id IS NULL
       OR pt.total_paid < c.amount
),
ar_by_utility AS (
    SELECT
        ua.utility_type,
        SUM(sc.outstanding_amount) AS outstanding_ar
    FROM shortfall_charges sc
    JOIN utility_accounts ua ON sc.account_id = ua.account_id
    GROUP BY ua.utility_type
),
duplicate_groups AS (
    SELECT
        c.account_id,
        c.billing_period,
        c.charge_type,
        c.amount,
        COUNT(*) AS group_size,
        SUM(CASE WHEN COALESCE(pt.total_paid, 0) = 0 THEN 1 ELSE 0 END) AS unpaid_in_group
    FROM charges c
    LEFT JOIN payment_totals pt
        ON c.charge_id = pt.charge_id
    GROUP BY c.account_id, c.billing_period, c.charge_type, c.amount
    HAVING COUNT(*) > 1
),
duplicate_exposure_by_utility AS (
    SELECT
        ua.utility_type,
        SUM((dg.group_size - 1) * dg.amount) AS duplicate_exposure,
        SUM(CASE WHEN dg.unpaid_in_group >= 1 THEN dg.amount ELSE 0 END) AS duplicate_ar_overlap
    FROM duplicate_groups dg
    JOIN utility_accounts ua ON dg.account_id = ua.account_id
    GROUP BY ua.utility_type
),
mismatch_charges AS (
    SELECT
        charge_id,
        account_id,
        ABS(amount - expected_amount) AS mismatch_amount
    FROM charges
    WHERE amount <> expected_amount
),
mismatch_exposure_by_utility AS (
    SELECT
        ua.utility_type,
        SUM(mc.mismatch_amount) AS amount_mismatch_exposure
    FROM mismatch_charges mc
    JOIN utility_accounts ua ON mc.account_id = ua.account_id
    GROUP BY ua.utility_type
),
account_counts AS (
    SELECT utility_type, COUNT(*) AS total_accounts
    FROM utility_accounts
    GROUP BY utility_type
),
billed_dollars_by_utility AS (
    SELECT
        ua.utility_type,
        SUM(c.amount) AS total_billed_dollars
    FROM charges c
    JOIN utility_accounts ua ON c.account_id = ua.account_id
    GROUP BY ua.utility_type
),
combined_exposure_by_utility AS (
    SELECT
        ac.utility_type,
        ac.total_accounts,
        bd.total_billed_dollars,
        COALESCE(ar.outstanding_ar, 0)
            + COALESCE(de.duplicate_exposure, 0)
            + COALESCE(me.amount_mismatch_exposure, 0)
            - COALESCE(de.duplicate_ar_overlap, 0) AS total_exposure_adjusted
    FROM account_counts ac
    JOIN billed_dollars_by_utility bd
        ON ac.utility_type = bd.utility_type
    LEFT JOIN ar_by_utility ar
        ON ac.utility_type = ar.utility_type
    LEFT JOIN duplicate_exposure_by_utility de
        ON ac.utility_type = de.utility_type
    LEFT JOIN mismatch_exposure_by_utility me
        ON ac.utility_type = me.utility_type
)
SELECT
    utility_type,
    total_accounts,
    total_billed_dollars,
    total_exposure_adjusted,
    ROUND(total_exposure_adjusted / total_billed_dollars * 100, 2) AS exposure_rate_pct
FROM combined_exposure_by_utility
ORDER BY exposure_rate_pct DESC;
-- Result: exposure_rate_pct is 5.42% (water), 5.40% (electric),
-- 5.34% (trash), 5.27% (gas) -- a spread of only 0.15 percentage
-- points across all four utility types. Check 4's ranking was a
-- bill-size artifact, confirmed: electric led by nearly 2 million
-- billed dollars over water despite both landing at essentially the
-- same ~5.4% exposure rate. Total billed dollars across all four
-- types sums to $16,097,113.22, and $864,504.66 / $16,097,113.22 =
-- 5.37%, the expected weighted average given the four individual
-- rates. No utility type is meaningfully more or less at risk than
-- any other once billed dollar volume is controlled for.
