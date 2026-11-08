"""QuickBite data generator (Step 3).

Creates about 60,000 orders over 12 months (1 Nov 2025 - 31 Oct 2026) plus
everything they need, with SIX PLANTED LEAKS that the later queries,
views and procedures must be able to find.

    python3 generator/generate_data.py            -> data/generated/quickbite_data.sql
                                                     data/generated/manifest.json

The output is a plain SQL file of multi-row INSERTs, loaded with:
    docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" quickbite' \
        < data/generated/quickbite_data.sql

Rules this file follows:
  * Standard library only. One random generator with a FIXED SEED, so every
    run produces exactly the same data (repeatable results for the report).
  * Every value respects the CHECK constraints in db/mysql/01_schema.sql.
    If one did not, MySQL would reject the row and the load would stop.
  * Reference data (regions, cities, leak types/rules) comes from 03_seed.sql;
    the CITIES table below must match its city_id values.
  * Derived values (subtotal, GMV, contribution) are NOT written; only the
    raw facts they are computed from. The summary at the end computes
    contribution with the locked formula, as a sanity check only.

Planted leaks (see LEAKS in manifest.json for the exact ids):
  L1 DISCOUNT_OVERSPEND    "Mega Feast Fest" (Jul-Dec 2026): FEAST60 = 60% off,
                           platform-funded, no minimum basket, and often stacked
                           with FEASTFREE. Coupon use also climbs every month.
  L2 DELIVERY_COST_OVERRUN 10 Hyderabad partners still on an old payout slab
                           (x1.8), and Bengaluru rain incentives set far too high.
  L3 DELAY_COST            6 slow restaurants: prep runs 12-35 min late, so
                           partners wait (wait_time_pay) and deliveries are late
                           (delay vouchers).
  L4 UNRECOVERED_REFUND    5 restaurants with many quality / missing-item refunds
                           that are never charged back (recovered_amount = 0).
  L5 GATEWAY_FEE_EXCESS    PAYU fee rises from 1.9% to 2.9% on 1 May 2026, and its
                           share of online payments keeps growing.
  L6 LOW_VALUE_ORDER       Tiny baskets (< Rs 149) with FREEDEL (free delivery,
                           no minimum basket) become more common every month.
"""

import bisect
import json
import random
from datetime import date, datetime, timedelta
from pathlib import Path

# ----------------------------------------------------------------------------
# 0. Settings
# ----------------------------------------------------------------------------
SEED = 2026
N_ORDERS = 60_000
N_CUSTOMERS = 14_000
START = datetime(2025, 11, 1)          # first order on or after this
END = datetime(2026, 11, 1)            # last order before this
MONTHS = 12
BATCH = 1000                           # rows per INSERT statement

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "data" / "generated"

rng = random.Random(SEED)


def money(x):
    """Round to paise. All money goes through here before it is stored."""
    return round(x + 1e-9, 2)


def month_index(t):
    """0 for Nov 2025 ... 11 for Oct 2026."""
    return (t.year - START.year) * 12 + t.month - START.month


def rand_time(lo, hi):
    """Uniform random datetime in [lo, hi), whole seconds."""
    return lo + timedelta(seconds=rng.randrange(int((hi - lo).total_seconds())))


# ----------------------------------------------------------------------------
# 1. Reference data that must match 03_seed.sql
# ----------------------------------------------------------------------------
# city_id: (name, number of restaurants, {month: probability that a day is rainy})
MONSOON = {6: 0.40, 7: 0.50, 8: 0.45, 9: 0.35}
CITIES = {
    1: ("Bengaluru", 55, {**MONSOON, 10: 0.30, 5: 0.15}),
    2: ("Mysuru",    10, {**MONSOON, 10: 0.25}),
    3: ("Chennai",   30, {10: 0.35, 11: 0.45, 12: 0.30}),
    4: ("Hyderabad", 32, {7: 0.30, 8: 0.30, 9: 0.30}),
    # 5 = Kochi: inactive, so no restaurants, partners or orders
    6: ("Mumbai",    45, {6: 0.55, 7: 0.65, 8: 0.55, 9: 0.40}),
    7: ("Pune",      22, {6: 0.40, 7: 0.50, 8: 0.40, 9: 0.30}),
    8: ("New Delhi", 40, {7: 0.25, 8: 0.25}),
    9: ("Gurugram",  18, {7: 0.25, 8: 0.25}),
}
DRY_DAY_RAIN = 0.03                     # chance of rain outside the wet months

# ----------------------------------------------------------------------------
# 2. Name lists and menus
# ----------------------------------------------------------------------------
FIRST = ["Aarav", "Aditi", "Akash", "Ananya", "Arjun", "Bhavya", "Chetan", "Deepa",
         "Divya", "Farhan", "Gauri", "Harish", "Ishaan", "Jyoti", "Karan", "Kavya",
         "Lakshmi", "Manoj", "Meera", "Nikhil", "Neha", "Omkar", "Pooja", "Pranav",
         "Priya", "Rahul", "Ritika", "Rohan", "Sahana", "Sanjay", "Shreya", "Siddharth",
         "Sneha", "Suresh", "Tanvi", "Uday", "Varun", "Vidya", "Vikram", "Yash",
         "Zoya", "Abdul", "Fatima", "Joseph", "Mary", "Gurpreet", "Harpreet", "Imran",
         "Kiran", "Madhu", "Naveen", "Pallavi", "Ravi", "Sunita", "Tarun", "Usha"]
LAST = ["Sharma", "Iyer", "Reddy", "Nair", "Patel", "Gupta", "Rao", "Khan", "Singh",
        "Menon", "Kulkarni", "Joshi", "Das", "Mehta", "Pillai", "Shetty", "Verma",
        "Chopra", "Banerjee", "Fernandes", "Hegde", "Naidu", "Bhat", "Kapoor",
        "Mishra", "Agarwal", "Gowda", "Desai", "Thomas", "Ali"]

PREFIX = ["Sri Krishna", "Royal", "Urban", "Green Leaf", "Spice Route", "Golden",
          "Namma", "Classic", "Little", "Big Bite", "Happy", "Mama's", "Hungry",
          "Blue Plate", "Red Chilli", "Chef's", "Grand", "Swadesh", "Metro", "Corner",
          "Silver Spoon", "Desi", "Fresh", "Bombay", "Madras"]

# cuisine: (restaurant name suffixes, [(item, category, base price)])
CUISINES = {
    "North Indian": (["Dhaba", "Punjabi Rasoi", "Tandoor House"], [
        ("Paneer Butter Masala", "Main Course", 260), ("Dal Makhani", "Main Course", 220),
        ("Butter Chicken", "Main Course", 330), ("Kadai Paneer", "Main Course", 250),
        ("Chole Masala", "Main Course", 190), ("Paneer Tikka", "Starter", 240),
        ("Chicken Tikka", "Starter", 290), ("Butter Naan", "Bread", 50),
        ("Tandoori Roti", "Bread", 30), ("Garlic Naan", "Bread", 65),
        ("Jeera Rice", "Rice", 150), ("Veg Pulao", "Rice", 180),
        ("Gulab Jamun", "Dessert", 80), ("Sweet Lassi", "Beverage", 90)]),
    "South Indian": (["Udupi Bhavan", "Dosa Camp", "Tiffin Centre"], [
        ("Masala Dosa", "Main Course", 110), ("Plain Dosa", "Main Course", 80),
        ("Rava Dosa", "Main Course", 120), ("Set Dosa", "Main Course", 95),
        ("Idli Vada", "Starter", 70), ("Medu Vada", "Starter", 60),
        ("Onion Uttapam", "Main Course", 110), ("Ven Pongal", "Main Course", 90),
        ("Lemon Rice", "Rice", 100), ("Curd Rice", "Rice", 90),
        ("Kesari Bath", "Dessert", 60), ("Filter Coffee", "Beverage", 40)]),
    "Biryani": (["Biryani House", "Biryani Paradise", "Dum Pukht"], [
        ("Chicken Dum Biryani", "Rice", 280), ("Mutton Biryani", "Rice", 360),
        ("Veg Biryani", "Rice", 220), ("Egg Biryani", "Rice", 230),
        ("Paneer Biryani", "Rice", 250), ("Chicken 65", "Starter", 240),
        ("Hyderabadi Haleem", "Main Course", 300), ("Mirchi Ka Salan", "Main Course", 60),
        ("Raita", "Side", 40), ("Double Ka Meetha", "Dessert", 90)]),
    "Chinese": (["Wok Express", "Dragon Kitchen", "Noodle Bar"], [
        ("Veg Hakka Noodles", "Main Course", 180), ("Schezwan Noodles", "Main Course", 200),
        ("Chicken Fried Rice", "Rice", 220), ("Veg Fried Rice", "Rice", 180),
        ("Gobi Manchurian", "Starter", 190), ("Chilli Chicken", "Starter", 260),
        ("Veg Momos", "Starter", 140), ("Chicken Momos", "Starter", 170),
        ("Spring Rolls", "Starter", 150), ("Hot and Sour Soup", "Soup", 120)]),
    "Pizza": (["Pizzeria", "Pizza Co", "Slice Shop"], [
        ("Margherita Pizza", "Main Course", 249), ("Farmhouse Pizza", "Main Course", 349),
        ("Pepperoni Pizza", "Main Course", 399), ("Paneer Tikka Pizza", "Main Course", 369),
        ("Pasta Alfredo", "Main Course", 279), ("Garlic Bread", "Side", 129),
        ("Cheesy Dip", "Side", 39), ("Choco Lava Cake", "Dessert", 109),
        ("Coke 500ml", "Beverage", 60)]),
    "Burgers": (["Burger Barn", "Grill House", "Burger Joint"], [
        ("Veg Burger", "Main Course", 129), ("Chicken Burger", "Main Course", 179),
        ("Cheese Burger", "Main Course", 199), ("French Fries", "Side", 99),
        ("Peri Peri Fries", "Side", 119), ("Chicken Wings", "Starter", 229),
        ("Chicken Nuggets", "Starter", 149), ("Cold Coffee", "Beverage", 129),
        ("Brownie Shake", "Beverage", 169)]),
    "Cafe": (["Cafe", "Bakehouse", "Coffee Roasters"], [
        ("Cappuccino", "Beverage", 160), ("Cold Brew", "Beverage", 190),
        ("Iced Tea", "Beverage", 130), ("Club Sandwich", "Main Course", 220),
        ("Blueberry Cheesecake", "Dessert", 260), ("Chocolate Brownie", "Dessert", 140),
        ("Butter Croissant", "Bakery", 120), ("Red Velvet Pastry", "Dessert", 150)]),
    "Street Food": (["Chaat Corner", "Roll Point", "Street Kitchen"], [
        ("Paneer Kathi Roll", "Main Course", 140), ("Chicken Kathi Roll", "Main Course", 160),
        ("Egg Roll", "Main Course", 110), ("Pav Bhaji", "Main Course", 140),
        ("Vada Pav", "Snack", 40), ("Samosa", "Snack", 30), ("Pani Puri", "Snack", 60),
        ("Bhel Puri", "Snack", 70), ("Masala Chai", "Beverage", 30)]),
}

# ----------------------------------------------------------------------------
# 3. Campaigns and coupons (hand-designed, because leak L1 lives here)
# ----------------------------------------------------------------------------
# (campaign_id, name, start, end, is_active)  -- "today" is after Oct 2026
CAMPAIGNS = [
    (1, "New Year Feast 2026", date(2025, 12, 20), date(2026, 1, 5),   False),
    (2, "Holi Splash 2026",    date(2026, 3, 1),   date(2026, 3, 5),   False),  # issued no coupons
    (3, "IPL Match Day 2026",  date(2026, 3, 26),  date(2026, 5, 31),  False),
    (4, "Monsoon Munchies",    date(2026, 6, 15),  date(2026, 9, 15),  False),
    (5, "Mega Feast Fest",     date(2026, 7, 1),   date(2026, 12, 31), True),   # L1
    (6, "Diwali Dhamaka 2026", date(2026, 10, 10), date(2026, 11, 15), True),
]
CAMPAIGN_DATES = {c[0]: (c[2], c[3]) for c in CAMPAIGNS}

# FREE-DELIVERY coupons are stored as FLAT with free_delivery = TRUE: they waive
# the delivery fee up to discount_value, so discount_amount = min(value, fee).
COUPON_COLS = ["coupon_id", "campaign_id", "coupon_code", "discount_type", "discount_value",
               "max_discount_amount", "funded_by", "restaurant_share_pct", "free_delivery",
               "minimum_basket_amount"]
COUPONS = [
    # id camp  code         type      value max  funded_by    share free  min   pick-weight
    (1,  None, "WELCOME100", "FLAT",    100, None, "PLATFORM",   0,   False, 199, 0),   # first order only
    (2,  None, "FREEDEL",    "FLAT",     50, None, "PLATFORM",   0,   True,    0, 2),   # L6
    (3,  None, "SAVE20",     "PERCENT",  20,   80, "SHARED",    50,   False, 249, 3),
    (4,  None, "RESTO15",    "PERCENT",  15,   60, "RESTAURANT", 100, False, 199, 2),
    (5,  None, "PARTY10",    "PERCENT",  10,  300, "RESTAURANT", 100, False, 999, 1),
    (6,  1,    "NEWYEAR30",  "PERCENT",  30,  120, "PLATFORM",   0,   False, 299, 6),
    (7,  3,    "IPL50",      "FLAT",     50, None, "SHARED",    40,   False, 299, 5),
    (8,  4,    "MONSOON25",  "PERCENT",  25,  100, "SHARED",    30,   False, 249, 5),
    (9,  5,    "FEAST60",    "PERCENT",  60,  150, "PLATFORM",   0,   False,   0, 9),   # L1
    (10, 5,    "FEASTFREE",  "FLAT",     60, None, "PLATFORM",   0,   True,    0, 0),   # L1, stacked only
    (11, 6,    "DIWALI40",   "PERCENT",  40,  200, "SHARED",    25,   False, 349, 7),
]
COUPON = {c[0]: dict(zip(COUPON_COLS + ["weight"], c)) for c in COUPONS}

# Payment gateways: (name, fee rate). PAYU's rate changes on 1 May 2026 (L5).
PAYU_RATE_CHANGE = datetime(2026, 5, 1)


def gateway_rate(gateway, t):
    if gateway == "PAYU":
        return 0.029 if t >= PAYU_RATE_CHANGE else 0.019
    return {"RAZORPAY": 0.019, "CASHFREE": 0.0175, "UPI_DIRECT": 0.0, "COD": 0.0}[gateway]


# ----------------------------------------------------------------------------
# 4. SQL output helpers
# ----------------------------------------------------------------------------
def sql_value(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, float):
        return f"{v:.2f}"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, datetime):
        return "'" + v.strftime("%Y-%m-%d %H:%M:%S") + "'"
    if isinstance(v, date):
        return "'" + v.isoformat() + "'"
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"


TABLES = {}   # table name -> (column list, list of row tuples), in FK-safe insert order


def table(name, columns):
    TABLES[name] = (columns, [])
    return TABLES[name][1]


customers = table("customer", ["customer_id", "full_name", "email", "phone",
                               "referred_by_customer_id", "created_at"])
restaurants = table("restaurant", ["restaurant_id", "city_id", "restaurant_name",
                                   "commission_pct", "is_active", "created_at"])
menu_items = table("menu_item", ["menu_item_id", "restaurant_id", "item_name", "category",
                                 "list_price", "is_available"])
partners = table("delivery_partner", ["partner_id", "city_id", "partner_name", "is_active"])
campaigns = table("campaign", ["campaign_id", "campaign_name", "start_date", "end_date",
                               "is_active"])
coupons = table("coupon", COUPON_COLS)
orders = table("orders", ["order_id", "customer_id", "restaurant_id", "order_time",
                          "order_status", "delivery_fee", "platform_fee", "packaging_fee",
                          "distance_km", "is_peak_period", "is_rainy_weather",
                          "cancellation_stage"])
order_items = table("order_item", ["order_id", "menu_item_id", "quantity", "unit_price"])
order_costs = table("order_cost", ["order_id", "support_cost"])
trips = table("delivery_trip", ["trip_id", "order_id", "partner_id", "assigned_at",
                                "picked_up_at", "delivered_at", "promised_delivery_at",
                                "promised_prep_minutes", "actual_prep_minutes",
                                "partner_payout", "incentive_amount", "wait_time_pay"])
payments = table("payment_transaction", ["payment_id", "order_id", "gateway_name",
                                         "payment_status", "transaction_amount",
                                         "gateway_fee", "transaction_time"])
refunds = table("refund", ["refund_id", "order_id", "refund_amount", "recovered_amount",
                           "responsibility", "refund_reason", "refund_status", "created_at"])
compensations = table("compensation", ["compensation_id", "order_id", "compensation_amount",
                                       "reason", "created_at"])
discount_usages = table("discount_usage", ["order_id", "coupon_id", "discount_amount",
                                           "used_at"])


# ----------------------------------------------------------------------------
# 5. Master data: customers, restaurants, menus, partners, campaigns, coupons
# ----------------------------------------------------------------------------
def person_name():
    return rng.choice(FIRST), rng.choice(LAST)


def build_customers():
    """35% existed before the year starts; the rest sign up month by month,
    more in later months (the business is growing)."""
    times = []
    n_old = int(N_CUSTOMERS * 0.35)
    for _ in range(n_old):
        times.append(rand_time(datetime(2024, 1, 1), START))
    weights = [1.06 ** m for m in range(MONTHS)]
    for _ in range(N_CUSTOMERS - n_old):
        m = rng.choices(range(MONTHS), weights)[0]
        lo = datetime(2025 + (10 + m) // 12, (10 + m) % 12 + 1, 1)
        hi = datetime(2025 + (11 + m) // 12, (11 + m) % 12 + 1, 1)
        times.append(rand_time(lo, hi))
    times.sort()                       # customer_id follows sign-up order

    info = []                          # per customer: created_at, activity
    for cid, created in enumerate(times, start=1):
        first, last = person_name()
        email = f"{first.lower()}.{last.lower()}{cid}@example.com"
        phone = rng.choice("6789") + "".join(rng.choice("0123456789") for _ in range(9))
        referrer = None
        if created >= START and cid > 1 and rng.random() < 0.20:
            referrer = rng.randint(1, cid - 1)   # always an EARLIER customer, never itself
        customers.append((cid, f"{first} {last}", email, phone, referrer, created))
        activity = rng.choices([0.15, 0.5, 1.0], [60, 30, 10])[0]
        info.append({"created": created, "activity": activity, "orders": 0})
    return info


def build_restaurants():
    """Restaurants with their menus. Returns per-restaurant info used later."""
    info = {}
    rid = 0
    mid = 0
    for city_id, (city_name, count, _) in CITIES.items():
        used = set()
        for _ in range(count):
            rid += 1
            cuisine = rng.choice(list(CUISINES))
            suffixes, items = CUISINES[cuisine]
            while True:
                name = f"{rng.choice(PREFIX)} {rng.choice(suffixes)}"
                if name not in used:
                    used.add(name)
                    break
            is_chain = rng.random() < 0.15
            commission = (rng.randrange(24, 33) if is_chain else rng.randrange(32, 51)) / 2
            if rng.random() < 0.88:
                created = rand_time(datetime(2023, 1, 1), START)
            else:
                created = rand_time(START, datetime(2026, 9, 1))   # opened during the year
            restaurants.append((rid, city_id, name, float(commission), True, created))
            info[rid] = {
                "city": city_id, "name": name, "commission": commission,
                "created": created, "closed": None,
                "packaging": rng.choice([0, 5, 10, 10, 15, 20]),
                "prep": rng.randint(12, 25),
                "popularity": rng.lognormvariate(0, 0.6),
                "slow": False, "refund_leak": False, "items": [],
            }
            # menu: most of the cuisine's items, each priced around its base price
            for item, category, base in rng.sample(items, rng.randint(len(items) - 3, len(items))):
                mid += 1
                price = max(20, round(base * rng.uniform(0.85, 1.25)))
                available = rng.random() > 0.05
                menu_items.append((mid, rid, item, category, float(price), available))
                info[rid]["items"].append((mid, float(price)))
    # 4% of the older restaurants closed during the year (is_active = FALSE)
    old = [r for r in info if info[r]["created"] < START]
    for r in rng.sample(old, round(len(info) * 0.04)):
        info[r]["closed"] = rand_time(datetime(2026, 3, 1), datetime(2026, 8, 1))
    # planted leaks L3 (slow kitchens) and L4 (refunds never charged back)
    big_cities = [r for r in old if info[r]["city"] in (1, 6, 8) and info[r]["closed"] is None]
    for r in rng.sample(big_cities, 6):
        info[r]["slow"] = True
    others = [r for r in old if not info[r]["slow"] and info[r]["closed"] is None]
    for r in rng.sample(others, 5):
        info[r]["refund_leak"] = True
    # rewrite is_active now that closures are known
    for i, row in enumerate(restaurants):
        if info[row[0]]["closed"] is not None:
            restaurants[i] = row[:4] + (False,) + row[5:]
    return info


def build_partners(rinfo):
    by_city = {}
    pid = 0
    for city_id, (_, count, _) in CITIES.items():
        by_city[city_id] = []
        for _ in range(round(count * 3.5)):
            pid += 1
            first, last = person_name()
            active = rng.random() > 0.03
            partners.append((pid, city_id, f"{first} {last}", active))
            by_city[city_id].append({"id": pid, "active": active, "legacy": False})
    for p in rng.sample(by_city[4], 10):           # L2: Hyderabad legacy payout slab
        p["legacy"] = True
        p["active"] = True
    for i, row in enumerate(partners):             # keep table rows in step
        if row[1] == 4:
            match = next(p for p in by_city[4] if p["id"] == row[0])
            partners[i] = row[:3] + (match["active"],)
    return by_city


def build_campaigns_and_coupons():
    for c in CAMPAIGNS:
        campaigns.append(c)
    for c in COUPONS:
        row = list(c[:10])
        row[4] = float(row[4])
        row[5] = None if row[5] is None else float(row[5])
        row[7] = float(row[7])
        row[9] = float(row[9])
        coupons.append(tuple(row))


# ----------------------------------------------------------------------------
# 6. Orders and everything that hangs off them
# ----------------------------------------------------------------------------
HOUR_WEIGHTS = [2, 1, 1, 1, 1, 1, 2, 4, 6, 6, 6, 8, 14, 16, 12, 7, 6, 7, 9, 14, 18, 17, 12, 6]
PEAK_HOURS = {12, 13, 14, 19, 20, 21, 22}


def order_times():
    """60,000 timestamps, more each month (about +6% a month), more at
    lunch and dinner, a little more at weekends. Returned sorted."""
    weights = [1.06 ** m for m in range(MONTHS)]
    counts = [round(N_ORDERS * w / sum(weights)) for w in weights]
    counts[-1] += N_ORDERS - sum(counts)
    times = []
    for m, n in enumerate(counts):
        first = datetime(2025 + (10 + m) // 12, (10 + m) % 12 + 1, 1)
        nxt = datetime(2025 + (11 + m) // 12, (11 + m) % 12 + 1, 1)
        days = [first + timedelta(days=d) for d in range((nxt - first).days)]
        day_w = [1.35 if d.weekday() >= 5 else 1.0 for d in days]
        for _ in range(n):
            d = rng.choices(days, day_w)[0]
            h = rng.choices(range(24), HOUR_WEIGHTS)[0]
            times.append(d + timedelta(hours=h, minutes=rng.randrange(60), seconds=rng.randrange(60)))
    times.sort()
    return times


RAIN = {}


def is_rainy(city_id, t):
    key = (city_id, t.date())
    if key not in RAIN:
        RAIN[key] = rng.random() < CITIES[city_id][2].get(t.month, DRY_DAY_RAIN)
    return RAIN[key]


def pick_customer(cinfo, created_list, t):
    """A customer who had already signed up at time t. Busy customers order
    more (rejection sampling on 'activity'); new sign-ups often order soon."""
    eligible = bisect.bisect_right(created_list, t)
    while True:
        if rng.random() < 0.25:
            idx = rng.randrange(max(0, eligible - 300), eligible)
        else:
            idx = rng.randrange(eligible)
        if rng.random() < cinfo[idx]["activity"]:
            return idx


def pick_restaurant(rinfo, rids, cum, t):
    while True:
        r = rids[bisect.bisect_left(cum, rng.random() * cum[-1])]
        info = rinfo[r]
        if info["created"] <= t and (info["closed"] is None or t < info["closed"]):
            return r


def build_basket(rinfo, r, m):
    """Returns [(menu_item_id, qty, unit_price)]. unit_price = price at order time."""
    items = rinfo[r]["items"]
    # L6: tiny baskets get more common every month
    if rng.random() < 0.04 + 0.012 * m:
        cheap = [it for it in items if it[1] < 130]
        if cheap:
            mid, price = rng.choice(cheap)
            qty = 1 if price * 2 >= 149 else rng.choice([1, 2])
            return [(mid, qty, price)]
    if rng.random() < 0.01:                                    # office party order
        chosen = rng.sample(items, min(len(items), 5))
        return [(mid, rng.randint(4, 10), price) for mid, price in chosen]
    n = min(len(items), rng.choices([1, 2, 3, 4, 5], [30, 35, 20, 10, 5])[0])
    chosen = rng.sample(items, n)
    return [(mid, rng.choices([1, 2, 3], [75, 20, 5])[0], price) for mid, price in chosen]


def coupon_discount(c, subtotal, delivery_fee):
    """Discount in rupees, or None if the coupon cannot apply."""
    if subtotal < c["minimum_basket_amount"]:
        return None
    if c["free_delivery"]:
        return money(min(c["discount_value"], delivery_fee)) if delivery_fee > 0 else None
    if c["discount_type"] == "FLAT":
        return money(min(c["discount_value"], subtotal))
    d = subtotal * c["discount_value"] / 100
    if c["max_discount_amount"] is not None:
        d = min(d, c["max_discount_amount"])
    return money(d)


def choose_coupons(t, m, subtotal, delivery_fee, first_order):
    """Returns [(coupon_id, discount)]. Usually 0 or 1 coupon; FEAST60 is
    often stacked with FEASTFREE (L1)."""
    if first_order and rng.random() < 0.7:
        d = coupon_discount(COUPON[1], subtotal, delivery_fee)
        if d:
            return [(1, d)]
    if rng.random() > 0.16 + 0.022 * m:                         # 16% -> 40% of orders
        return []
    options, weights = [], []
    for cid, c in COUPON.items():
        if c["weight"] == 0:
            continue
        if c["campaign_id"] is not None:
            lo, hi = CAMPAIGN_DATES[c["campaign_id"]]
            if not (lo <= t.date() <= hi):
                continue
        d = coupon_discount(c, subtotal, delivery_fee)
        if not d:
            continue
        w = c["weight"]
        if cid == 2 and subtotal < 149:
            w = 12 + m                                          # L6: FREEDEL pushed on tiny baskets
        options.append((cid, d))
        weights.append(w)
    if not options:
        return []
    chosen = [rng.choices(options, weights)[0]]
    if chosen[0][0] == 9 and rng.random() < 0.45:               # L1: stacking
        d = coupon_discount(COUPON[10], subtotal, delivery_fee)
        if d:
            chosen.append((10, d))
    return chosen


def choose_gateway(m):
    """COD slowly falls; PAYU's share grows (L5)."""
    names = ["COD", "UPI_DIRECT", "RAZORPAY", "PAYU", "CASHFREE"]
    weights = [16 - m * 0.5, 35, 24 - m, 10 + m * 1.8, 15]
    return rng.choices(names, weights)[0]


def build_orders(cinfo, rinfo, partners_by_city):
    created_list = [c["created"] for c in cinfo]
    rids = list(rinfo)
    cum, total = [], 0.0
    for r in rids:
        total += rinfo[r]["popularity"]
        cum.append(total)

    times = order_times()
    in_progress_from = len(times) - 40          # the last 40 orders are still open
    trip_id = payment_id = refund_id = comp_id = 0
    stats = {"monthly": [[0, 0.0, 0.0] for _ in range(MONTHS)]}  # orders, revenue, contribution

    for oid, t in enumerate(times, start=1):
        m = month_index(t)
        ci = pick_customer(cinfo, created_list, t)
        cust = cinfo[ci]
        first_order = cust["orders"] == 0
        cust["orders"] += 1
        r = pick_restaurant(rinfo, rids, cum, t)
        R = rinfo[r]
        city = R["city"]
        peak = t.hour in PEAK_HOURS
        rainy = is_rainy(city, t)
        km = money(min(15.0, 0.8 + rng.gammavariate(2.0, 1.6)))

        basket = build_basket(rinfo, r, m)
        subtotal = money(sum(q * p for _, q, p in basket))

        # fees: free delivery on big baskets; surge for rain and peak
        if subtotal >= 499:
            delivery_fee = 0.0
        else:
            delivery_fee = float(min(70, round(25 + 5 * max(0.0, km - 3)))
                                 + (20 if rainy else 0) + (10 if peak else 0))
        platform_fee = 5.0 if t < datetime(2026, 4, 1) else 7.0
        packaging_fee = float(R["packaging"])

        # status
        if oid > in_progress_from:
            status = rng.choice(["PLACED", "ACCEPTED", "PREPARING", "PICKED_UP"])
            stage = None
        elif rng.random() < (0.10 if R["slow"] else 0.045):
            status = "CANCELLED"
            stage = rng.choices(["BEFORE_ACCEPT", "AFTER_ACCEPT", "AFTER_PICKUP"], [50, 35, 15])[0]
        else:
            status, stage = "DELIVERED", None

        orders.append((oid, ci + 1, r, t, status, delivery_fee, platform_fee, packaging_fee,
                       km, peak, rainy, stage))
        for mid, q, p in basket:
            order_items.append((oid, mid, q, p))

        # coupons (APPLIES, M:N)
        used = choose_coupons(t, m, subtotal, delivery_fee, first_order)
        for cid, d in used:
            discount_usages.append((oid, cid, d, t))
        discount_total = money(sum(d for _, d in used))
        platform_discount = sum(d * (1 - COUPON[c]["restaurant_share_pct"] / 100) for c, d in used)
        customer_pays = money(subtotal + delivery_fee + platform_fee + packaging_fee - discount_total)
        assert customer_pays > 0

        # ---------------- delivery trip (FULFILLED_BY, 1:1) ----------------
        has_trip = status in ("ACCEPTED", "PREPARING", "PICKED_UP", "DELIVERED") or \
            stage in ("AFTER_ACCEPT", "AFTER_PICKUP")
        payout = incentive = wait_pay = 0.0
        delivered_at = None
        delay_min = 0.0
        if has_trip:
            pool = [p for p in partners_by_city[city] if p["active"] or m < 6]
            partner = rng.choice(pool)
            assigned = t + timedelta(seconds=rng.randint(60, 300))
            promised_prep = R["prep"]
            actual_prep = max(5, round(promised_prep + rng.gauss(0, 3) + (rng.randint(0, 5) if peak else 0)))
            if R["slow"]:
                actual_prep += rng.randint(12, 35)                      # L3
            ride_min_per_km = 3.2 * (1.3 if rainy else 1.0) * (1.15 if peak else 1.0)
            promised_delivery = t + timedelta(minutes=promised_prep + 3 + 8 + km * 3.2 + 10)
            arrive = assigned + timedelta(minutes=rng.randint(3, 12))
            ready = t + timedelta(minutes=actual_prep)
            picked = max(arrive, ready) + timedelta(minutes=rng.randint(1, 3))
            wait_min = max(0.0, (ready - arrive).total_seconds() / 60)

            if status == "DELIVERED" or stage == "AFTER_PICKUP":
                payout = 25 + 7 * km
                if partner["legacy"]:
                    payout *= 1.8                                       # L2
                if rainy:
                    incentive = rng.uniform(45, 70) if city == 1 and t >= datetime(2026, 5, 1) \
                        else rng.uniform(15, 25)                        # L2 Bengaluru rain
                elif peak:
                    incentive = rng.uniform(5, 15)
                wait_pay = 1.5 * max(0.0, wait_min - 5)                 # first 5 min unpaid
            elif stage == "AFTER_ACCEPT":
                payout = 20.0                                           # cancellation pay
            payout, incentive, wait_pay = money(payout), money(incentive), money(wait_pay)

            picked_at = picked if status in ("PICKED_UP", "DELIVERED") or stage == "AFTER_PICKUP" else None
            if status == "DELIVERED":
                ride = max(2.0, km * ride_min_per_km + rng.gauss(0, 3))
                delivered_at = picked + timedelta(minutes=ride)
                delay_min = (delivered_at - promised_delivery).total_seconds() / 60
            trip_id += 1
            trips.append((trip_id, oid, partner["id"], assigned, picked_at, delivered_at,
                          promised_delivery, promised_prep,
                          actual_prep if picked_at else None,
                          payout, incentive, wait_pay))

        # ---------------- payment(s) (PAID_VIA, 1:N) ----------------
        gateway = choose_gateway(m)
        gateway_fee = 0.0
        if gateway == "COD":
            if status == "DELIVERED":                                   # cash taken at the door
                payment_id += 1
                payments.append((payment_id, oid, "COD", "SUCCESS", customer_pays, 0.0, delivered_at))
        else:
            pay_t = t + timedelta(seconds=rng.randint(5, 40))
            if rng.random() < 0.03:                                     # first attempt fails
                payment_id += 1
                payments.append((payment_id, oid, gateway, "FAILED", customer_pays, 0.0, pay_t))
                pay_t += timedelta(seconds=rng.randint(30, 120))
            pay_status = "REVERSED" if stage == "BEFORE_ACCEPT" else "SUCCESS"
            if pay_status == "SUCCESS":
                gateway_fee = money(customer_pays * gateway_rate(gateway, t))
            payment_id += 1
            payments.append((payment_id, oid, gateway, pay_status, customer_pays, gateway_fee, pay_t))

        # ---------------- refunds and compensation ----------------
        refund_rows, comp_rows = [], []
        paid_online = gateway != "COD"
        if stage in ("AFTER_ACCEPT", "AFTER_PICKUP") and paid_online:
            resp = rng.choices(["RESTAURANT", "CUSTOMER"], [70, 30])[0] if stage == "AFTER_ACCEPT" \
                else rng.choices(["PARTNER", "PLATFORM", "CUSTOMER"], [50, 30, 20])[0]
            if resp != "CUSTOMER":                                      # customer-cancelled: no refund
                recovered = 0.0
                if resp == "RESTAURANT" and not R["refund_leak"]:
                    recovered = customer_pays
                elif resp == "PARTNER" and rng.random() < 0.5:
                    recovered = min(customer_pays, 100.0)
                refund_rows.append((customer_pays, money(recovered), resp, "CANCELLED", "PROCESSED",
                                    t + timedelta(minutes=rng.randint(10, 90))))
            if stage == "AFTER_PICKUP" and rng.random() < 0.5:
                comp_rows.append((50.0, "SERVICE_FAILURE", t + timedelta(minutes=rng.randint(30, 120))))

        if status == "DELIVERED":
            refund_rate = 0.18 if R["refund_leak"] else 0.04
            if delay_min > 20:
                refund_rate += 0.05
            if rng.random() < refund_rate:
                reasons = ["MISSING_ITEM", "WRONG_ITEM", "QUALITY", "OTHER"]
                weights = [30, 15, 30, 5]
                if delay_min > 20:
                    reasons.append("LATE_DELIVERY")
                    weights.append(40)
                reason = rng.choices(reasons, weights)[0]
                line = max(basket, key=lambda x: x[2])
                if reason in ("MISSING_ITEM", "WRONG_ITEM"):
                    amount = line[2]
                    resp = "RESTAURANT" if rng.random() < 0.9 else "PARTNER"
                elif reason == "QUALITY":
                    amount = subtotal * rng.uniform(0.3, 1.0)
                    resp = "RESTAURANT"
                elif reason == "LATE_DELIVERY":
                    amount = delivery_fee + subtotal * 0.1 if delivery_fee + subtotal * 0.1 > 0 else 20
                    resp = "PARTNER" if rng.random() < 0.6 else "PLATFORM"
                else:
                    amount = rng.uniform(20, 80)
                    resp = "PLATFORM"
                amount = money(min(amount, customer_pays))
                created = delivered_at + timedelta(minutes=rng.randint(10, 2880))
                if created >= END - timedelta(days=3):
                    rstatus = rng.choice(["REQUESTED", "APPROVED"])
                else:
                    rstatus = "REJECTED" if rng.random() < 0.08 else "PROCESSED"
                recovered = 0.0
                if rstatus == "PROCESSED":
                    if resp == "RESTAURANT":
                        if R["refund_leak"]:
                            recovered = amount if rng.random() < 0.05 else 0.0     # L4
                        elif rng.random() < 0.85:
                            recovered = amount
                    elif resp == "PARTNER" and rng.random() < 0.5:
                        recovered = min(amount, 100.0)
                refund_rows.append((amount, money(recovered), resp, reason, rstatus, created))
            if delay_min > 15 and rng.random() < 0.4:
                comp_rows.append((float(rng.choice([25, 40, 50, 75])), "DELAY_VOUCHER",
                                  delivered_at + timedelta(minutes=rng.randint(5, 60))))
            elif rng.random() < 0.005:
                comp_rows.append((float(rng.choice([20, 30, 50])), "GOODWILL",
                                  delivered_at + timedelta(minutes=rng.randint(30, 600))))

        for amount, recovered, resp, reason, rstatus, created in refund_rows:
            refund_id += 1
            refunds.append((refund_id, oid, amount, recovered, resp, reason, rstatus, created))
        for amount, reason, created in comp_rows:
            comp_id += 1
            compensations.append((comp_id, oid, amount, reason, created))

        # ---------------- order_cost (weak entity, one row per order) ----------------
        if refund_rows or comp_rows or stage in ("AFTER_ACCEPT", "AFTER_PICKUP"):
            support = money(rng.uniform(25, 60))
        elif rng.random() < 0.03:
            support = money(rng.uniform(10, 25))                       # a chat with no refund
        else:
            support = 0.0
        order_costs.append((oid, support))

        # ---------------- sanity summary (delivered orders, locked formula) ----------------
        if status == "DELIVERED":
            revenue = subtotal * R["commission"] / 100 + delivery_fee + platform_fee + packaging_fee
            refund_loss = sum(a - rec for a, rec, _, _, s, _ in refund_rows if s in ("APPROVED", "PROCESSED")) \
                + sum(a for a, _, _ in comp_rows)
            contribution = revenue - platform_discount - (payout + incentive + wait_pay) \
                - gateway_fee - support - refund_loss
            s = stats["monthly"][m]
            s[0] += 1
            s[1] += revenue
            s[2] += contribution
    return stats


# ----------------------------------------------------------------------------
# 7. Write the SQL file
# ----------------------------------------------------------------------------
HEADER = """-- =====================================================================
--  QuickBite generated data  (made by generator/generate_data.py, seed {seed})
--  DO NOT EDIT BY HAND: re-run the generator instead.
--
--  Needs 01_schema.sql, 02_roles.sql and 03_seed.sql to be loaded first.
--  WARNING: the TRUNCATEs below empty every generated table first, so
--  loading this file again replaces (not duplicates) the generated data.
--  Seed tables (region, city, leak_type, leak_rule, app_role, app_user)
--  and audit_log are NOT touched.
-- =====================================================================
USE quickbite;

-- TRUNCATE is refused on a table that a foreign key points to, even an empty
-- one, so FK checks are switched off just for the truncates.
SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE leakage_record;
TRUNCATE TABLE recommendation;
{truncates}
SET FOREIGN_KEY_CHECKS = 1;   -- back ON: every row below is checked against its parent

-- One transaction: either all generated rows go in, or none do.
START TRANSACTION;
"""


def write_sql(path):
    truncates = "\n".join(f"TRUNCATE TABLE {t};" for t in reversed(list(TABLES)))
    with open(path, "w", encoding="utf-8") as f:
        f.write(HEADER.format(seed=SEED, truncates=truncates))
        for name, (cols, rows) in TABLES.items():
            f.write(f"\n-- {name}: {len(rows):,} rows\n")
            col_list = ", ".join(cols)
            for i in range(0, len(rows), BATCH):
                values = ",\n".join("(" + ", ".join(sql_value(v) for v in row) + ")"
                                    for row in rows[i:i + BATCH])
                f.write(f"INSERT INTO {name} ({col_list}) VALUES\n{values};\n")
        f.write("\nCOMMIT;\n\n"
                "-- Refresh InnoDB statistics now: right after a bulk load into empty tables\n"
                "-- they can lag for minutes, and the optimizer then plans joins badly.\n"
                "ANALYZE TABLE " + ", ".join(TABLES) + ";\n")
        f.write("\n-- Row counts after loading\n")
        f.write("SELECT " + ",\n       ".join(f"(SELECT COUNT(*) FROM {t}) AS {t}" for t in TABLES) + ";\n")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    cinfo = build_customers()
    rinfo = build_restaurants()
    partners_by_city = build_partners(rinfo)
    build_campaigns_and_coupons()
    stats = build_orders(cinfo, rinfo, partners_by_city)

    sql_path = OUT_DIR / "quickbite_data.sql"
    write_sql(sql_path)

    manifest = {
        "seed": SEED,
        "row_counts": {name: len(rows) for name, (_, rows) in TABLES.items()},
        "leaks": {
            "L1_discount": {"campaign": "Mega Feast Fest", "coupons": ["FEAST60", "FEASTFREE"]},
            "L2_delivery_cost": {
                "hyderabad_legacy_partner_ids": sorted(p["id"] for p in partners_by_city[4] if p["legacy"]),
                "bengaluru_rain_incentive_from": "2026-05-01"},
            "L3_delay_restaurant_ids": sorted(r for r in rinfo if rinfo[r]["slow"]),
            "L4_refund_restaurant_ids": sorted(r for r in rinfo if rinfo[r]["refund_leak"]),
            "L5_gateway": {"gateway": "PAYU", "fee_2_9_pct_from": "2026-05-01"},
            "L6_low_value": {"coupon": "FREEDEL", "basket_below": 149},
        },
    }
    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2))

    print(f"Wrote {sql_path.relative_to(ROOT)} ({sql_path.stat().st_size / 1e6:.1f} MB)")
    for name, n in manifest["row_counts"].items():
        print(f"  {name:20s} {n:>8,}")
    print("\nDelivered orders per month (contribution = locked formula, a sanity check only):")
    print("  month     orders   revenue/order   contribution/order")
    for m, (n, rev, con) in enumerate(stats["monthly"]):
        label = datetime(2025 + (10 + m) // 12, (10 + m) % 12 + 1, 1).strftime("%b %Y")
        print(f"  {label}  {n:>7,}   {rev / n:>12.2f}   {con / n:>16.2f}")
    print("\nPlanted leak ids:", json.dumps(manifest["leaks"], indent=None))


if __name__ == "__main__":
    main()
