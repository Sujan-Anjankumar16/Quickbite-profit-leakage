# QuickBite Profit Leakage Analyzer

DBMS mini project (PES University, UE24CS351A, Experiential Learning Level 3).

QuickBite's orders and revenue keep growing while net profit falls. This system computes the **contribution (profit) of every order**, finds **where, why and how much** profit leaks (discounts, delivery cost, refunds, delays, low-value segments), and produces **ranked recommendations** with an estimated saving and demand risk.

## Stack

| Part | Technology | Holds |
|---|---|---|
| Source of truth | MySQL 8.4 | all transactional data, leak analysis, users and roles |
| Flexible data | MongoDB 7 | order events, feedback, analyst leak notes, saved scenarios |
| Cache | Redis 7 | dashboard KPIs and leaderboards |
| App | Next.js | UI and API routes |

## Technology justification

Each kind of data lives in the store that fits how it is shaped and used.

| Data | Store | Why this store |
|---|---|---|
| Orders, items, trips, payments, refunds, coupons, customers, restaurants, partners | **MySQL** | Money and relationships. These rows must never contradict each other, so they need foreign keys, CHECK constraints, transactions (a refund and its order commit together) and exact `DECIMAL` arithmetic. The profit formulas join many tables, which is what SQL is built for. |
| Leak rules, leak records, recommendations, users and roles, audit log | **MySQL** | They are computed from the order data and must stay consistent with it. Stored procedures, triggers and per-role privileges (RBAC inside the database) all live next to the data. |
| `order_events` | **MongoDB** | An append-only timeline whose fields depend on the event: a payment failure carries a gateway and error code, a support chat carries minutes and a transcript id. A flexible document per event avoids a sparse table with dozens of nullable columns. |
| `feedback` | **MongoDB** | Free text plus a variable list of tags, read one order at a time; arrays and multikey indexes fit naturally. |
| `leak_notes` | **MongoDB** | Analyst notes: free text, tags, a status, full CRUD, and full-text search. The schema changes with how analysts work. A `$jsonSchema` validator still enforces the essential fields, and the API checks that the linked MySQL id exists. |
| `saved_scenarios` | **MongoDB** | "What if" settings and results whose shape differs from scenario to scenario. |
| Dashboard KPIs and leaderboards | **Redis** | Read on every page load but change only when data or a detection run changes. Caching them for 10 minutes stops repeated scans of 60,000 orders. A sorted set (`ZADD`/`ZRANGE REV`) keeps the restaurant leaderboard already ranked. Keys contain the latest detection run id and the role, so a new run is never served stale data and roles never share results. |

MySQL stays the single source of truth: MongoDB and Redis hold either data that never takes part in the profit calculation (notes, events, feedback, scenarios) or a disposable copy that can be rebuilt at any time (the cache).

## Run it

```bash
cp .env.example .env        # set MYSQL_ROOT_PASSWORD
docker compose up -d        # MySQL, MongoDB, Redis
docker compose ps           # wait until all are "healthy"
```

MySQL is reachable from the host on **localhost:3307** (set by `DB_PORT` in `.env`; chosen because a native MySQL often already uses 3306). Inside Docker it is still 3306.

```bash
# prove the constraints work (16 statements must fail, then everything is rolled back)
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --force quickbite' < db/mysql/tests/constraint_tests.sql
```

On first start MySQL runs every file in `db/mysql/` in name order (`01_schema`, `02_roles`, `03_seed`). To start again from an empty database: `docker compose down -v && docker compose up -d`.

### Generate and load the data (Step 3)

```bash
python3 -m venv .venv && source .venv/bin/activate     # once
pip3 install -r generator/requirements.txt              # once (bcrypt, for hash_password.py)
python3 generator/generate_data.py                      # writes data/generated/quickbite_data.sql
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" quickbite' < data/generated/quickbite_data.sql
```

The generator uses a fixed random seed, so every run produces the same ~60,000 orders (Nov 2025 to Oct 2026) with six planted leaks. Loading the file again replaces the generated tables; seed tables are not touched.

```bash
# data checks: part A must be all zeros, part B shows the planted leaks
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t quickbite' < db/mysql/tests/data_checks.sql
# DML demo (inserts, updates, deletes, savepoint; ends in ROLLBACK, 2 errors are expected)
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --force -t quickbite' < db/mysql/demo/dml_demo.sql
```

### Views and contribution function (Step 4)

```bash
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" quickbite' < db/mysql/04_views.sql      # only needed on an existing volume
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t quickbite' < db/mysql/tests/view_checks.sql   # every mismatch must be 0
```

| View | One row per | Granted to |
|---|---|---|
| `v_order_financials` | order: subtotal, GMV, revenue, every cost, contribution, delay | analyst |
| `v_monthly_kpi` | month (closed orders) | analyst, viewer |
| `v_city_scorecard` | city, with state and zone | analyst, viewer |
| `v_restaurant_scorecard` | restaurant | analyst, viewer |
| `v_coupon_performance` | coupon | analyst |

`fn_order_contribution(order_id)` returns the same contribution as the view for one order (EXECUTE granted to analyst).

### Queries (Step 5)

```bash
docker compose exec -T mysql sh -c 'mysql -uqb_analyst_user -pAnalyst@Dev123 -t quickbite' < db/mysql/queries/05_queries.sql
```

| Kind | Queries |
|---|---|
| Joins | J1 five-table join with region self-join, J2 anti-joins, J3 customer self-join, J4 RIGHT JOIN, J5 JSON rule settings + LATERAL, J6 benchmark join |
| Nested | N1 subquery in HAVING, N2 IN, N3 scalar subquery, N4 `> ALL`, N5 NOT IN, N6 derived table |
| Correlated | C1 refund rate vs own city, C2 NOT EXISTS, C3 per-city top item |
| Recursive | R1 region tree roll-up, R2 referral chains, R3 month calendar with window functions |
| CTE + window | P1 Pareto of leak types, P2 Pareto of restaurants (which make up 80% of leak loss, latest run, primary leaks) |

### Leak detection and recommendations (Step 6)

```bash
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" quickbite' < db/mysql/06_procedures.sql   # only needed on an existing volume
docker compose exec -T mysql sh -c 'mysql -uqb_analyst_user -pAnalyst@Dev123 -t quickbite -e "CALL sp_detect_leaks(\"2025-11-01\", \"2026-11-01\", @run, @leaks); CALL sp_generate_recommendations(@run, @recos); SELECT @run, @leaks, @recos;"'
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --force -t quickbite' < db/mysql/tests/procedure_checks.sql   # 7 errors are expected (trigger tests)
```

- `sp_detect_leaks(from, to, OUT run_id, OUT leaks)` applies the six active leak rules to closed orders in one CTE pipeline, marks the largest leak on each order as primary, and caps it at the order's loss so primary leaks never exceed total loss.
- `sp_generate_recommendations(run_id, OUT n)` groups a run's leaks by the target that can fix them (coupon, partner, restaurant, city, gateway) and ranks them by estimated saving and demand risk.
- Triggers block self-referral and referral cycles, validate recommendation targets and status moves (NEW → ACCEPTED/REJECTED → IMPLEMENTED), and audit leak-rule, recommendation-status and app-user changes (actor from `@app_user_id`).

### MongoDB and Redis (Step 7)

```bash
docker compose exec mongo mongosh --quiet quickbite /docker-entrypoint-initdb.d/01_init.js   # only needed on an existing volume
cd web && npm install            # once
npm run seed:notes               # leak notes linked to the latest detection run
npm run test:step7               # validators, indexes, leak-notes CRUD + roles, Redis cache: all PASS
```

| Collection | Validator highlights | Indexes |
|---|---|---|
| `order_events` | event_type and actor enums, date, free `payload` | (order_id, at), (event_type, at) |
| `feedback` | rating 1-5 int, comment ≤ 1000, unique tags | unique order_id, (rating, created_at), tags |
| `leak_notes` | leak_ref {kind, id}, leak_type enum, title 3-120, tags `^[a-z0-9-]{2,30}$`, status enum, author | (leak_type, created_at), order_id, tags, leak_ref, text(title, body) |
| `saved_scenarios` | name, author, params object | unique (author, name) |

Leak-notes rules: everyone can read; analysts and admins create; only the author or an admin updates or deletes. leak_type and order_id are copied from the linked MySQL row, never trusted from the client.

## Repository layout

```
db/mysql/01_schema.sql            23 tables with all constraints (DDL)
db/mysql/02_roles.sql             MySQL roles qb_admin / qb_analyst / qb_viewer
db/mysql/03_seed.sql              reference data: regions, cities, leak types, leak rules, app users
db/mysql/04_views.sql             order financials + KPI/scorecard views, fn_order_contribution, grants
db/mysql/06_procedures.sql        functions, triggers, sp_detect_leaks, sp_generate_recommendations
db/mysql/tests/constraint_tests.sql   proves every kind of constraint rejects bad data
db/mysql/tests/data_checks.sql    integrity checks on generated data + planted-leak evidence
db/mysql/tests/view_checks.sql    view = function for every order, totals reconcile, worked example
db/mysql/tests/procedure_checks.sql  latest detection run, reconciliation, every trigger
db/mysql/demo/dml_demo.sql        DML demonstration (one transaction, rolled back)
db/mysql/queries/05_queries.sql   20 join, nested, correlated, recursive and Pareto CTE queries
generator/generate_data.py        data generator (standard library, fixed seed)
generator/hash_password.py        bcrypt hash for app_user passwords
data/generated/                   generator output (git-ignored)
db/mongo/01_init.js               MongoDB collections, $jsonSchema validators, indexes, sample data
web/lib/                          data layer: MySQL pool per role, leak-notes CRUD, Redis cache, dashboards
web/scripts/seed-leak-notes.mjs   seeds leak notes linked to real MySQL leak rows
web/scripts/test-step7.mjs        MongoDB + leak-notes CRUD + Redis tests
docs/diagrams/                    ER diagram and relational schema
docs/quickbite.dbml               DBML for dbdiagram.io, generated from 01_schema.sql
```

## Build progress

| Step | Rubric item (marks) | Status |
|---|---|---|
| 0 | ER diagram (2), relational schema (3) | done |
| 1 | Repo + Docker skeleton, Git from day one (part of 2) | done |
| 2 | DDL with constraints (4), DB roles (part of 4) | done: run and verified 6 Nov 2026 |
| 3 | Seed data + generator, DML (4) | done: 8 Nov 2026 (60,000 orders, 6 planted leaks) |
| 4 | Views + `fn_order_contribution` | done: 8 Nov 2026 |
| 5 | Nested / correlated / recursive / join queries (4) | done: 8 Nov 2026 |
| 6 | Procedures, functions, triggers, CTEs (6) | done: 8 Nov 2026 |
| 7 | NoSQL creation (4), NoSQL feature + RUD (7), technology justification (1) | done: 8 Nov 2026 |
| 8 | Next.js UI (3), API integration (2), login + RBAC (4) | next |
| 9 | Documentation, demo, viva prep (2 + 4) | |

## Core formulas

- **Revenue** = food subtotal × commission % + delivery fee + platform fee + packaging fee
- **Platform discount** = discount × (1 − restaurant_share_pct / 100)
- **Delivery cost** = partner payout + incentive + wait-time pay
- **Refund loss** = refund + compensation − recovered
- **Contribution** = revenue − platform discount − delivery cost − gateway fee − support cost − refund loss
- Refunds count only when APPROVED or PROCESSED. A **cancelled** order has revenue 0 and platform discount 0, and its cancellation refunds are ignored; it still loses its delivery, gateway, support and compensation costs.
- **Leak amount** = cost in excess of a benchmark (never the whole cost); the largest leak on an order is its **primary** leak.
