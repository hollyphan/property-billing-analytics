"""
Synthetic data generator for property-billing-analytics.

Generates six tables modeling a multifamily property management billing
portfolio: properties, units, leases, utility_accounts, charges, payments.
All data is synthetic, modeled on common patterns in property utility
billing and payments -- not real Zego or SDG&E data.

Fixed random.seed(42) for reproducibility, matching project convention.
"""

import csv
import os
import random
from datetime import date, timedelta
from dateutil.relativedelta import relativedelta
from faker import Faker

SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

OUTPUT_DIR = "data"
os.makedirs(OUTPUT_DIR, exist_ok=True)

N_PROPERTIES = 150
MIN_UNITS, MAX_UNITS = 30, 60
N_MONTHS = 12
START_MONTH = date(2025, 10, 1)  # 12 months of history ending Sept 2026

MARKETS = ["San Diego", "Phoenix", "Austin", "Dallas", "Denver", "Las Vegas", "Tampa"]
UTILITY_TYPES = ["water", "electric", "gas", "trash"]
RATE_PLANS = {"water": "tiered", "electric": "usage_based", "gas": "usage_based", "trash": "flat"}
BASE_RATE = {"water": 45, "electric": 85, "gas": 40, "trash": 25}

# ~18% of properties are deliberately seeded worse on exceptions/delinquency.
# This flag is NOT written to any output table -- it only biases generation
# probabilities, so the "finding" has to come from SQL analysis, not a label.
problem_property_ids = set(random.sample(range(1, N_PROPERTIES + 1), k=round(N_PROPERTIES * 0.18)))

# ---------- properties ----------
properties = []
for pid in range(1, N_PROPERTIES + 1):
    n_units = random.randint(MIN_UNITS, MAX_UNITS)
    properties.append({
        "property_id": pid,
        "name": f"{fake.street_name()} {random.choice(['Apartments', 'Flats', 'Residences', 'Commons', 'Court'])}",
        "market": random.choice(MARKETS),
        "unit_count": n_units,
    })

# ---------- units ----------
units = []
unit_id_counter = 1
unit_ids_by_property = {}
for p in properties:
    ids = []
    for u in range(p["unit_count"]):
        units.append({
            "unit_id": unit_id_counter,
            "property_id": p["property_id"],
            "unit_number": f"{random.randint(1, 9)}{random.choice('ABCDEFGH')}{u + 1:02d}",
        })
        ids.append(unit_id_counter)
        unit_id_counter += 1
    unit_ids_by_property[p["property_id"]] = ids

# ---------- leases (supports turnover -- multiple leases per unit over time) ----------
leases = []
lease_id_counter = 1
tenant_id_counter = 1
window_start = START_MONTH
window_end = START_MONTH + relativedelta(months=N_MONTHS) - timedelta(days=1)
unit_leases = {}

for u in units:
    unit_leases[u["unit_id"]] = []
    cursor = window_start - relativedelta(months=random.randint(0, 6))
    while cursor < window_end:
        lease_len_months = random.choice([6, 12, 12, 12, 18, 24])
        lease_end = cursor + relativedelta(months=lease_len_months) - timedelta(days=1)
        lease = {
            "lease_id": lease_id_counter,
            "unit_id": u["unit_id"],
            "tenant_id": tenant_id_counter,
            "lease_start": cursor,
            "lease_end": lease_end,
        }
        leases.append(lease)
        unit_leases[u["unit_id"]].append(lease)
        lease_id_counter += 1
        tenant_id_counter += 1
        gap_days = random.choice([0, 0, 0, 7, 14, 30])
        cursor = lease_end + timedelta(days=1) + timedelta(days=gap_days)

# ---------- utility_accounts (one per unit per utility type) ----------
utility_accounts = []
account_id_counter = 1
accounts_by_unit = {}
for u in units:
    accts = []
    for ut in UTILITY_TYPES:
        acct = {
            "account_id": account_id_counter,
            "unit_id": u["unit_id"],
            "utility_type": ut,
            "rate_plan": RATE_PLANS[ut],
        }
        utility_accounts.append(acct)
        accts.append(acct)
        account_id_counter += 1
    accounts_by_unit[u["unit_id"]] = accts


def leases_active_in(unit_id, period_start, period_end):
    return [l for l in unit_leases.get(unit_id, [])
            if l["lease_start"] <= period_end and l["lease_end"] >= period_start]


# ---------- charges + payments ----------
charges = []
payments = []
charge_id_counter = 1
payment_id_counter = 1

for month_idx in range(N_MONTHS):
    period_start = window_start + relativedelta(months=month_idx)
    period_end = period_start + relativedelta(months=1) - timedelta(days=1)
    days_in_month = (period_end - period_start).days + 1

    for p in properties:
        is_problem = p["property_id"] in problem_property_ids
        exception_rate = 0.12 if is_problem else 0.03
        late_rate = 0.35 if is_problem else 0.12
        failed_rate = 0.08 if is_problem else 0.015

        for unit_id in unit_ids_by_property[p["property_id"]]:
            active_leases = leases_active_in(unit_id, period_start, period_end)
            if not active_leases:
                continue  # vacant this month -- no charges generated

            for acct in accounts_by_unit[unit_id]:
                base_rate = BASE_RATE[acct["utility_type"]] * random.uniform(0.85, 1.2)

                full_month_lease = (
                    len(active_leases) == 1
                    and active_leases[0]["lease_start"] <= period_start
                    and active_leases[0]["lease_end"] >= period_end
                )

                if not full_month_lease:
                    occupied_days = 0
                    for l in active_leases:
                        seg_start = max(l["lease_start"], period_start)
                        seg_end = min(l["lease_end"], period_end)
                        occupied_days += (seg_end - seg_start).days + 1
                    occupied_days = min(occupied_days, days_in_month)
                    expected_amount = round(base_rate * occupied_days / days_in_month, 2)
                    if random.random() < 0.40:
                        amount = round(base_rate, 2)  # billing system failed to prorate
                    else:
                        amount = expected_amount
                else:
                    expected_amount = round(base_rate, 2)
                    amount = expected_amount

                is_missed = False
                is_duplicate = False
                roll = random.random()
                if roll < exception_rate:
                    sub = random.random()
                    if sub < 0.45:
                        is_missed = True
                    elif sub < 0.85:
                        is_duplicate = True
                    elif full_month_lease:
                        amount = round(expected_amount * random.choice([0.5, 1.5, 1.8]), 2)

                if is_missed:
                    continue  # the missed charge itself -- no row created

                charge_type = "prorated" if not full_month_lease or amount != expected_amount else "regular"

                charge = {
                    "charge_id": charge_id_counter,
                    "account_id": acct["account_id"],
                    "billing_period": period_start,
                    "charge_type": charge_type,
                    "amount": amount,
                    "expected_amount": expected_amount,
                }
                charges.append(charge)
                charge_id_counter += 1

                due_date = period_start + relativedelta(months=1)
                pay_roll = random.random()
                if pay_roll < failed_rate:
                    status, payment_date, amount_paid = "failed", "", 0.0
                elif pay_roll < failed_rate + late_rate:
                    status = "late"
                    payment_date = due_date + timedelta(days=random.randint(6, 55))
                    amount_paid = amount
                else:
                    status = "on-time"
                    offset = random.randint(-5, 5)
                    payment_date = due_date + timedelta(days=offset)
                    amount_paid = amount

                payments.append({
                    "payment_id": payment_id_counter,
                    "charge_id": charge["charge_id"],
                    "payment_date": payment_date,
                    "amount_paid": amount_paid,
                    "status": status,
                })
                payment_id_counter += 1

                if is_duplicate:
                    dup_charge = {
                        "charge_id": charge_id_counter,
                        "account_id": acct["account_id"],
                        "billing_period": period_start,
                        "charge_type": charge_type,
                        "amount": amount,
                        "expected_amount": expected_amount,
                    }
                    charges.append(dup_charge)
                    charge_id_counter += 1
                    if random.random() < 0.3:
                        payments.append({
                            "payment_id": payment_id_counter,
                            "charge_id": dup_charge["charge_id"],
                            "payment_date": due_date + timedelta(days=random.randint(0, 20)),
                            "amount_paid": amount,
                            "status": "on-time",
                        })
                        payment_id_counter += 1


def write_csv(filename, rows, fieldnames):
    with open(os.path.join(OUTPUT_DIR, filename), "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


write_csv("properties.csv", properties, ["property_id", "name", "market", "unit_count"])
write_csv("units.csv", units, ["unit_id", "property_id", "unit_number"])
write_csv("leases.csv", leases, ["lease_id", "unit_id", "tenant_id", "lease_start", "lease_end"])
write_csv("utility_accounts.csv", utility_accounts, ["account_id", "unit_id", "utility_type", "rate_plan"])
write_csv("charges.csv", charges, ["charge_id", "account_id", "billing_period", "charge_type", "amount", "expected_amount"])
write_csv("payments.csv", payments, ["payment_id", "charge_id", "payment_date", "amount_paid", "status"])

print(f"properties: {len(properties)}")
print(f"units: {len(units)}")
print(f"leases: {len(leases)}")
print(f"utility_accounts: {len(utility_accounts)}")
print(f"charges: {len(charges)}")
print(f"payments: {len(payments)}")
