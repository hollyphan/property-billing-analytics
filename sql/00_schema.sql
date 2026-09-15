-- Property Billing & Payments Analytics -- schema
-- 6 normalized tables, no billing_exceptions table: exceptions are detected
-- purely via SQL from charges/payments, not pre-labeled. See handoff doc.

CREATE DATABASE IF NOT EXISTS property_billing_analytics;
USE property_billing_analytics;

DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS charges;
DROP TABLE IF EXISTS utility_accounts;
DROP TABLE IF EXISTS leases;
DROP TABLE IF EXISTS units;
DROP TABLE IF EXISTS properties;

CREATE TABLE properties (
    property_id INT PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    market      VARCHAR(50)  NOT NULL,
    unit_count  INT          NOT NULL
);

CREATE TABLE units (
    unit_id     INT PRIMARY KEY,
    property_id INT NOT NULL,
    unit_number VARCHAR(10) NOT NULL,
    FOREIGN KEY (property_id) REFERENCES properties(property_id)
);

-- A unit can have multiple leases over time (turnover). This is what makes
-- proration-error detection meaningful: a charge's expected amount depends
-- on which lease(s) were active during that billing period.
CREATE TABLE leases (
    lease_id    INT PRIMARY KEY,
    unit_id     INT NOT NULL,
    tenant_id   INT NOT NULL,
    lease_start DATE NOT NULL,
    lease_end   DATE NOT NULL,
    FOREIGN KEY (unit_id) REFERENCES units(unit_id)
);

CREATE TABLE utility_accounts (
    account_id    INT PRIMARY KEY,
    unit_id       INT NOT NULL,
    utility_type  VARCHAR(20) NOT NULL,  -- water / electric / gas / trash
    rate_plan     VARCHAR(20) NOT NULL,  -- descriptive label only
    FOREIGN KEY (unit_id) REFERENCES units(unit_id)
);

-- expected_amount is generated alongside the actual billed amount as a
-- simplified stand-in for a full rate engine (locked decision, Sept 2026).
-- Diffing amount vs. expected_amount is how SQL detects proration errors.
CREATE TABLE charges (
    charge_id       INT PRIMARY KEY,
    account_id      INT NOT NULL,
    billing_period  DATE NOT NULL,
    charge_type     VARCHAR(20) NOT NULL,  -- regular / prorated
    amount          DECIMAL(10,2) NOT NULL,
    expected_amount DECIMAL(10,2) NOT NULL,
    FOREIGN KEY (account_id) REFERENCES utility_accounts(account_id)
);

CREATE TABLE payments (
    payment_id   INT PRIMARY KEY,
    charge_id    INT NOT NULL,
    payment_date DATE NULL,
    amount_paid  DECIMAL(10,2) NOT NULL,
    status       VARCHAR(10) NOT NULL,  -- on-time / late / failed
    FOREIGN KEY (charge_id) REFERENCES charges(charge_id)
);
