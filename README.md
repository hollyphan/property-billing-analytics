# Property Billing & Payments Analytics

SQL portfolio project analyzing billing accuracy and payment delinquency
across a synthetic multifamily property management portfolio.

**All data is synthetic.** It is modeled on common patterns in property
utility billing and payments, grounded in real professional experience
(payments/utility billing software for multifamily properties; utility
company billing/variance/exception analysis) -- but it is not real data
from any employer.

## Business question

Where is a property billing system leaking revenue or creating payment
friction across a portfolio of properties, and which properties or
utility types need intervention first?

## Schema

Six normalized tables: `properties`, `units`, `leases`, `utility_accounts`,
`charges`, `payments`. See `sql/00_schema.sql` for full DDL and column
notes. No `billing_exceptions` table -- billing exceptions (duplicate,
missed, and proration-error charges) are detected purely via SQL from
`charges` and `payments`, not pre-labeled.

## Setup

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python3 generate_data.py          # writes data/*.csv, seed 42, reproducible
mysql -u root -p -e "CREATE DATABASE IF NOT EXISTS property_billing_analytics;"
mysql --local-infile=1 -u root -p property_billing_analytics < sql/00_schema.sql
mysql --local-infile=1 -u root -p property_billing_analytics < sql/00_load_data.sql
```

## Analysis files

See [`FINDINGS.md`](FINDINGS.md) for the write-up behind each completed
file -- business question, what the data shows, and recommendations.

- `sql/01_data_cleaning.sql` -- structural and referential integrity
  checks (NULLs, invalid ranges, date logic, orphaned foreign keys)
- `sql/02_billing_exceptions.sql`
- `sql/03_payment_delinquency.sql`
- `sql/04_portfolio_variance_trend.sql`
- `sql/05_revenue_at_risk_summary.sql`

Dashboard (Power BI) built from file 05's output.
