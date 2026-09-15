-- Load generated CSVs (data/*.csv) into the schema. Run from the repo root:
-- mysql --local-infile=1 -u root -p property_billing_analytics < sql/00_load_data.sql

USE property_billing_analytics;

LOAD DATA LOCAL INFILE 'data/properties.csv'
INTO TABLE properties
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n' IGNORE 1 LINES
(property_id, name, market, unit_count);

LOAD DATA LOCAL INFILE 'data/units.csv'
INTO TABLE units
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n' IGNORE 1 LINES
(unit_id, property_id, unit_number);

LOAD DATA LOCAL INFILE 'data/leases.csv'
INTO TABLE leases
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n' IGNORE 1 LINES
(lease_id, unit_id, tenant_id, lease_start, lease_end);

LOAD DATA LOCAL INFILE 'data/utility_accounts.csv'
INTO TABLE utility_accounts
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n' IGNORE 1 LINES
(account_id, unit_id, utility_type, rate_plan);

LOAD DATA LOCAL INFILE 'data/charges.csv'
INTO TABLE charges
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n' IGNORE 1 LINES
(charge_id, account_id, billing_period, charge_type, amount, expected_amount);

LOAD DATA LOCAL INFILE 'data/payments.csv'
INTO TABLE payments
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n' IGNORE 1 LINES
(payment_id, charge_id, @payment_date, amount_paid, status)
SET payment_date = NULLIF(@payment_date, '');
