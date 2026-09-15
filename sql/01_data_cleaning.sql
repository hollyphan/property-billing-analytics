-- Property Billing & Payments Analytics -- data cleaning
-- Verifies structural integrity of the raw loaded data before any
-- business-logic exception detection happens in 02_billing_exceptions.sql.
-- Scope: NULLs in required fields, and out-of-range/invalid values.
-- (Duplicate charges, missing billing periods, and proration mismatches
-- are intentionally NOT checked here -- those are business exceptions
-- detected in 02, not data-cleaning issues.)

USE property_billing_analytics;

-- ---------------------------------------------------------------------
-- 1. charges: NULLs in required columns, non-positive amounts
-- ---------------------------------------------------------------------
-- Every column in `charges` is declared NOT NULL in the schema, so this
-- check mainly confirms that constraint actually held during load (a
-- non-strict sql_mode can silently coerce a NULL into a NOT NULL column
-- instead of rejecting it). amount/expected_amount <= 0 would mean a
-- real utility charge of zero or negative dollars, which doesn't make
-- sense for this business and would indicate a generator or load bug.
SELECT COUNT(*) AS invalid_charge_rows
FROM charges
WHERE charge_id IS NULL
OR account_id IS NULL
OR billing_period IS NULL
OR charge_type IS NULL
OR amount IS NULL OR amount <= 0
OR expected_amount IS NULL OR expected_amount <= 0;
-- Result: 0. charges is clean -- no missing values, no non-positive
-- amounts across all 323,649 rows.

-- ---------------------------------------------------------------------
-- 2. payments: NULLs in required columns, invalid status, non-positive
--    amount_paid -- with two intentional exceptions
-- ---------------------------------------------------------------------
-- payment_date is the one column in the whole schema allowed to be NULL.
-- Checked separately: every NULL payment_date lines up exactly with
-- status = 'failed' (8,534 rows, matching the known failed-payment
-- count with no other status mixed in) -- a failed payment never has a
-- payment date because it never happened. Same logic for amount_paid:
-- every row with amount_paid <= 0 is also exactly status = 'failed'.
-- Both are the schema correctly representing "this payment never went
-- through," not data-quality bugs, so neither condition is flagged
-- below on its own. Instead, amount_paid <= 0 is only flagged when
-- status != 'failed' -- i.e. a payment that claims to have succeeded
-- but has no real dollar amount behind it, which would be a genuine
-- problem worth catching.
--
-- Also note: an earlier version of this check surfaced a real bug --
-- payments.status (and likely other trailing text columns across the
-- schema) had a stray carriage return appended to every value, from a
-- Windows-style \r\n CSV being loaded with LINES TERMINATED BY '\n'.
-- Fixed at the source in sql/00_load_data.sql; data was reloaded from
-- source CSVs and all row counts were re-verified unchanged.
SELECT COUNT(*) AS invalid_payment_rows
FROM payments
WHERE payment_id IS NULL
OR charge_id IS NULL
OR amount_paid IS NULL
OR (status != 'failed' AND amount_paid <= 0)
OR status IS NULL OR status NOT IN ('on-time', 'late', 'failed');
-- Result: 0. payments is clean -- no missing values, no invalid
-- statuses, no successful payment with a non-positive amount, across
-- all 319,325 rows.

-- ---------------------------------------------------------------------
-- 3. leases: lease_end on or before its own lease_start
-- ---------------------------------------------------------------------
-- A lease can't logically end on or before the day it starts. Flagging
-- lease_start = lease_end too (not just strictly after) since a
-- same-day lease doesn't make sense for this business either.
SELECT COUNT(*) AS invalid_lease_rows
FROM leases
WHERE lease_start >= lease_end;
-- Result: 0. No lease has a start/end date out of order, across all
-- 10,870 leases.

-- ---------------------------------------------------------------------
-- 4. payments: payment_date before the billing_period it's paying for
-- ---------------------------------------------------------------------
-- Joins payments to charges on charge_id to bring billing_period into
-- the same row as payment_date. A payment dated before the period it's
-- covering would mean money arrived before the bill even existed.
-- Failed payments (NULL payment_date) are automatically excluded here,
-- not filtered explicitly -- SQL's three-valued logic means
-- `NULL < billing_period` evaluates to NULL, not TRUE, so WHERE drops
-- those rows on its own. That's the correct behavior: a failed payment
-- has nothing meaningful to check against a billing period.
SELECT COUNT(*) AS invalid_payment_date_rows
FROM payments
JOIN charges
    ON payments.charge_id = charges.charge_id
WHERE payment_date < billing_period;
-- Result: 0. No payment predates the billing period it's covering,
-- across all 319,325 payments.

-- ---------------------------------------------------------------------
-- 5. Referential integrity: orphaned foreign keys across every
--    parent/child relationship in the schema
-- ---------------------------------------------------------------------
-- Every table's storage engine is InnoDB, and each FK is declared as a
-- real CONSTRAINT (confirmed via SHOW CREATE TABLE), so InnoDB enforces
-- these at insert time regardless of sql_mode -- unlike NOT NULL, there
-- is no non-strict-mode loophole for foreign keys. These checks were
-- expected to come back clean; run anyway to confirm the assumption
-- holds rather than relying on the constraint blindly.
--
-- Technique: LEFT JOIN child to parent, then check WHERE on the
-- PARENT table's key IS NULL -- that column only goes NULL when the
-- join found no match. Checking the child's own FK column instead
-- would be meaningless, since it's NOT NULL by schema and could never
-- flag anything regardless of whether a real orphan exists.

SELECT COUNT(*) AS orphaned_property_rows
FROM units
LEFT JOIN properties
    ON units.property_id = properties.property_id
WHERE properties.property_id IS NULL;
-- Result: 0. Every unit belongs to a real property.

SELECT COUNT(*) AS orphaned_unit_rows
FROM leases
LEFT JOIN units
    ON leases.unit_id = units.unit_id
WHERE units.unit_id IS NULL;
-- Result: 0. Every lease belongs to a real unit.

SELECT COUNT(*) AS orphaned_utility_rows
FROM utility_accounts
LEFT JOIN units
    ON utility_accounts.unit_id = units.unit_id
WHERE units.unit_id IS NULL;
-- Result: 0. Every utility account belongs to a real unit.

SELECT COUNT(*) AS orphaned_account_rows
FROM charges
LEFT JOIN utility_accounts
    ON charges.account_id = utility_accounts.account_id
WHERE utility_accounts.account_id IS NULL;
-- Result: 0. Every charge belongs to a real utility account.

SELECT COUNT(*) AS orphaned_charge_rows
FROM payments
LEFT JOIN charges
    ON payments.charge_id = charges.charge_id
WHERE charges.charge_id IS NULL;
-- Result: 0. Every payment belongs to a real charge.

-- ---------------------------------------------------------------------
-- Summary: the loaded dataset is structurally clean across all six
-- tables (150 properties, 6,781 units, 10,870 leases, 27,124 utility
-- accounts, 323,649 charges, 319,325 payments) -- no missing values, no
-- invalid ranges, no backwards dates, no orphaned foreign keys. Ready
-- for business-logic exception detection in 02_billing_exceptions.sql.
