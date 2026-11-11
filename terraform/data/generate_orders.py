#!/usr/bin/env python3
"""Generate the synthetic order dataset for the workshop.

Run ONCE locally to (re)produce `orders.json` next to this script:

    python3 generate_orders.py

This is NOT part of provisioning — the committed `orders.json` is the source of
truth. Regeneration is deterministic (fixed seed) so the same command always
yields the same dataset. Tweak the constants below and re-run to change it.

Output shape: a JSON array of DynamoDB-marshalled items
(`{"order_id": {"S": "..."}, ...}`), exactly the form
`aws dynamodb batch-write-item` consumes, so the bash loader needs no
transform of individual attributes.

Invariants enforced (so the agents' `lookup_order` tool never breaks):
  - `estimated_delivery` and `shipping_address` are ALWAYS present
    (the tool reads them as `item[...]`, not `.get()`).
  - `tracking` is OMITTED for `processing`/`cancelled` orders (the only
    optional attribute; tool reads it via `.get()`).
  - `items` line items use the canonical 10-product catalog (exact names +
    prices), so orders stay consistent with the Milvus catalog + MCP inventory.
  - `total` is ALWAYS present and ALWAYS equals sum(qty*price) over `items`,
    formatted to cents (e.g. "149.97") — precomputed so analytics code
    (module 900's sandboxed analysis) can aggregate it directly.
"""

import datetime
import json
import os
import random

# Deterministic: same seed -> identical dataset every run.
random.seed(20260703)

# "Now" baseline for the 495 generated orders. order_date spans the ~12 months
# ending here; estimated_delivery is a few days after order_date.
#
# DELIBERATELY FIXED, not date.today(): the Agents using a sandbox lab asks the
# agent to chart "2026-Q1", and a fixed anchor guarantees that quarter always
# falls inside the generated window. A relative anchor would silently empty that
# quarter once the window rolled past it.
NOW = datetime.date(2026, 7, 3)

# The five hero orders are anchored to PROVISIONING time instead, because the
# labs talk about them in the present tense ("I ordered a laptop last week") and
# read their estimated_delivery out loud. With a fixed anchor those dates went
# stale as soon as the event was more than a few weeks after the commit, so the
# agent would report a laptop shipped months ago and still undelivered.
TODAY = datetime.date.today()


def days_ago(n: int) -> str:
    return (TODAY - datetime.timedelta(days=n)).isoformat()


def days_ahead(n: int) -> str:
    return (TODAY + datetime.timedelta(days=n)).isoformat()

TOTAL_ORDERS = 500
FIRST_ID = 1001  # ORD-1001 .. ORD-1500

# Canonical product catalog — MUST match
# tbd/400-memory-milvus/customer-agent/seed_products.py
# (names + prices). FAQ pseudo-products (id 101-103) are not orderable.
CATALOG = [
    ("Laptop Pro 15", 1299.99),
    ("Wireless Mouse", 29.99),
    ("USB-C Hub", 49.99),
    ("Noise Cancelling Headphones", 249.99),
    ("Mechanical Keyboard", 89.99),
    ("4K Monitor 27-inch", 399.99),
    ("Webcam HD Pro", 79.99),
    ("Portable Charger 20000mAh", 39.99),
    ("Wireless Earbuds", 59.99),
    ("Laptop Stand", 34.99),
]

STATUSES = ["shipped", "delivered", "processing", "cancelled", "returned"]
# Weights make the mix realistic (most orders delivered/shipped).
STATUS_WEIGHTS = [0.28, 0.42, 0.12, 0.08, 0.10]

# tracking is only meaningful once an order has left the warehouse.
STATUS_WITHOUT_TRACKING = {"processing", "cancelled"}

PAYMENT_METHODS = ["credit_card", "debit_card", "gift_card"]
PAYMENT_WEIGHTS = [0.6, 0.3, 0.1]

CHANNELS = ["web", "mobile"]
CHANNEL_WEIGHTS = [0.65, 0.35]

FIRST_NAMES = [
    "Jane", "John", "Alice", "Bob", "Carol", "David", "Emma", "Frank", "Grace",
    "Henry", "Ivy", "Jack", "Karen", "Liam", "Mia", "Noah", "Olivia", "Peter",
    "Quinn", "Rachel", "Sam", "Tina", "Uma", "Victor", "Wendy", "Xander",
    "Yara", "Zach", "Aria", "Ben", "Chloe", "Daniel", "Ella", "Felix",
]
LAST_NAMES = [
    "Doe", "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia",
    "Miller", "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez",
    "Gonzalez", "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson",
    "Lee", "Perez", "Thompson", "White", "Harris", "Sanchez", "Clark",
    "Nguyen", "Patel", "Kim", "Chen", "Singh", "Kumar", "Ali",
]

# City -> (state 2-letter, region, ZIP). region groups states for geo analysis.
CITIES = [
    ("Seattle", "WA", "West", "98101"),
    ("Portland", "OR", "West", "97201"),
    ("San Francisco", "CA", "West", "94102"),
    ("Los Angeles", "CA", "West", "90001"),
    ("Phoenix", "AZ", "West", "85001"),
    ("Denver", "CO", "West", "80202"),
    ("Austin", "TX", "South", "73301"),
    ("Dallas", "TX", "South", "75201"),
    ("Houston", "TX", "South", "77001"),
    ("Atlanta", "GA", "South", "30301"),
    ("Miami", "FL", "South", "33101"),
    ("Charlotte", "NC", "South", "28201"),
    ("Chicago", "IL", "Central", "60601"),
    ("Minneapolis", "MN", "Central", "55401"),
    ("Kansas City", "MO", "Central", "64101"),
    ("Columbus", "OH", "Central", "43085"),
    ("New York", "NY", "East", "10001"),
    ("Boston", "MA", "East", "02101"),
    ("Philadelphia", "PA", "East", "19019"),
    ("Washington", "DC", "East", "20001"),
]

STREETS = [
    "Main St", "Oak Ave", "Pine Rd", "Maple Dr", "Cedar Ln", "Elm St",
    "Washington Blvd", "Park Ave", "Lake Dr", "Sunset Blvd", "Hill Rd",
    "River Rd", "Broadway", "Market St", "Union Ave",
]


def marshal(order: dict) -> dict:
    """Convert a plain order dict to DynamoDB attribute-value form.

    Every field is a String (S). `items` is JSON-encoded into a single String
    attribute (matches the existing seed pattern and what `lookup_order`
    expects: `json.loads(item["items"])`). `tracking` is only included when
    present in the source dict, so it is genuinely absent for
    processing/cancelled orders.
    """
    out = {}
    for k, v in order.items():
        if k == "items":
            out[k] = {"S": json.dumps(v)}
        else:
            out[k] = {"S": str(v)}
    return out


def period_of(date_iso: str) -> str:
    """Map an ISO date (YYYY-MM-DD) to a fiscal period bucket like '2026-Q1'.

    Used as the orders GSI hash key so the code-exec broker can Query a quarter
    slice instead of scanning the whole table.
    """
    y, m, _ = date_iso.split("-")
    q = (int(m) - 1) // 3 + 1
    return f"{y}-Q{q}"


def make_items() -> list:
    """1-3 distinct line items from the catalog, each qty 1-3."""
    n = random.choices([1, 2, 3], weights=[0.55, 0.30, 0.15])[0]
    chosen = random.sample(CATALOG, n)
    return [
        {"name": name, "qty": random.randint(1, 3), "price": price}
        for name, price in chosen
    ]


def order_total(items: list) -> str:
    """Order total = sum(qty*price), formatted to cents (matches lookup_order's
    on-the-fly computation in the 500 mcp-server, minus the '$')."""
    return f"{sum(i['qty'] * i['price'] for i in items):.2f}"


def make_address():
    city, state, region, zip_code = random.choice(CITIES)
    num = random.randint(100, 9999)
    street = random.choice(STREETS)
    address = f"{num} {street}, {city}, {state} {zip_code}"
    return address, state, region


def build_order(order_id: str, status: str) -> dict:
    """Build one plain order dict honoring the tool's field invariants."""
    address, state, region = make_address()
    order_date = NOW - datetime.timedelta(days=random.randint(0, 364))
    # estimated_delivery: 2-8 days after the order was placed. ALWAYS present.
    est_delivery = order_date + datetime.timedelta(days=random.randint(2, 8))

    # NOTE: keep the random-call order exactly as-is (address -> dates ->
    # customer -> items -> payment -> channel); reordering shifts the seeded
    # stream and silently regenerates every non-hero order.
    order = {
        "order_id": order_id,
        "customer": f"{random.choice(FIRST_NAMES)} {random.choice(LAST_NAMES)}",
        "status": status,
        "estimated_delivery": est_delivery.isoformat(),
        "shipping_address": address,
        "items": make_items(),
        "order_date": order_date.isoformat(),
        "period": period_of(order_date.isoformat()),
        "region": region,
        "state": state,
        "payment_method": random.choices(PAYMENT_METHODS, weights=PAYMENT_WEIGHTS)[0],
        "channel": random.choices(CHANNELS, weights=CHANNEL_WEIGHTS)[0],
    }
    # total derived AFTER the dict (consumes no randomness, so the seeded
    # stream — and therefore every previously generated order — is unchanged).
    order["total"] = order_total(order["items"])
    # tracking: only for orders that have left the warehouse.
    if status not in STATUS_WITHOUT_TRACKING:
        order["tracking"] = f"1Z999AA{random.randint(10_000_000_00, 99_999_999_99)}"
    return order


# --- Hero orders: hand-curated, one per status, stable IDs for docs/examples ---
def hero_orders() -> list:
    heroes = [
        {
            "order_id": "ORD-1001",
            "customer": "Jane Doe",
            "status": "shipped",
            "tracking": "1Z999AA10123456784",
            "estimated_delivery": days_ahead(1),
            "shipping_address": "123 Main St, Seattle, WA 98101",
            "items": [{"name": "Laptop Pro 15", "qty": 1, "price": 1299.99}],
            "order_date": days_ago(6),
            "region": "West",
            "state": "WA",
            "payment_method": "credit_card",
            "channel": "web",
        },
        {
            "order_id": "ORD-1002",
            "customer": "John Smith",
            "status": "delivered",
            "tracking": "1Z999AA10987654321",
            "estimated_delivery": days_ago(16),
            "shipping_address": "456 Oak Ave, Portland, OR 97201",
            "items": [
                {"name": "Wireless Mouse", "qty": 1, "price": 29.99},
                {"name": "USB-C Hub", "qty": 2, "price": 49.99},
            ],
            "order_date": days_ago(21),
            "region": "West",
            "state": "OR",
            "payment_method": "debit_card",
            "channel": "mobile",
        },
        {
            # processing: no tracking yet (attribute omitted)
            "order_id": "ORD-1003",
            "customer": "Alice Johnson",
            "status": "processing",
            "estimated_delivery": days_ahead(6),
            "shipping_address": "789 Pine Rd, San Francisco, CA 94102",
            "items": [{"name": "Noise Cancelling Headphones", "qty": 1, "price": 249.99}],
            "order_date": days_ago(2),
            "region": "West",
            "state": "CA",
            "payment_method": "credit_card",
            "channel": "web",
        },
        {
            # cancelled: no tracking (attribute omitted)
            "order_id": "ORD-1004",
            "customer": "Bob Williams",
            "status": "cancelled",
            "estimated_delivery": days_ago(8),
            "shipping_address": "321 Cedar Ln, Austin, TX 73301",
            "items": [{"name": "4K Monitor 27-inch", "qty": 1, "price": 399.99}],
            "order_date": days_ago(14),
            "region": "South",
            "state": "TX",
            "payment_method": "gift_card",
            "channel": "mobile",
        },
        {
            "order_id": "ORD-1005",
            "customer": "Carol Martinez",
            "status": "returned",
            "tracking": "1Z999AA10555512345",
            "estimated_delivery": days_ago(34),
            "shipping_address": "654 Maple Dr, Chicago, IL 60601",
            "items": [
                {"name": "Mechanical Keyboard", "qty": 1, "price": 89.99},
                {"name": "Wireless Earbuds", "qty": 1, "price": 59.99},
            ],
            "order_date": days_ago(40),
            "region": "Central",
            "state": "IL",
            "payment_method": "credit_card",
            "channel": "web",
        },
    ]
    # Derive totals rather than hand-writing them, so they can never drift
    # from the line items. `period` is derived for the same reason: the hero
    # dates move with provisioning time, so a hand-written quarter would be
    # wrong for most of the year and the GSI would file the order under a
    # quarter it does not belong to.
    for h in heroes:
        h["total"] = order_total(h["items"])
        h["period"] = period_of(h["order_date"])
    return heroes


def main():
    orders = hero_orders()
    hero_count = len(orders)

    for i in range(hero_count, TOTAL_ORDERS):
        order_id = f"ORD-{FIRST_ID + i}"
        status = random.choices(STATUSES, weights=STATUS_WEIGHTS)[0]
        orders.append(build_order(order_id, status))

    marshalled = [marshal(o) for o in orders]

    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "orders.json")
    with open(out_path, "w") as f:
        json.dump(marshalled, f, indent=2)
        f.write("\n")

    # Summary to stdout for the operator running the generator.
    by_status = {}
    for o in orders:
        by_status[o["status"]] = by_status.get(o["status"], 0) + 1
    print(f"Wrote {len(marshalled)} orders to {out_path}")
    print(f"  hero orders: {hero_count} (ORD-1001..ORD-{FIRST_ID + hero_count - 1})")
    print(f"  status mix : {by_status}")


if __name__ == "__main__":
    main()
