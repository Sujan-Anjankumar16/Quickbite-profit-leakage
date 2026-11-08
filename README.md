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

## Repository layout

```
db/mysql/01_schema.sql            23 tables with all constraints (DDL)
db/mysql/02_roles.sql             MySQL roles qb_admin / qb_analyst / qb_viewer
db/mysql/03_seed.sql              reference data: regions, cities, leak types, leak rules, app users
db/mysql/tests/constraint_tests.sql   proves every kind of constraint rejects bad data
db/mysql/tests/data_checks.sql    integrity checks on generated data + planted-leak evidence
db/mysql/demo/dml_demo.sql        DML demonstration (one transaction, rolled back)
generator/generate_data.py        data generator (standard library, fixed seed)
generator/hash_password.py        bcrypt hash for app_user passwords
data/generated/                   generator output (git-ignored)
db/mongo/                         Mongo collections and validators (Step 7)
docs/diagrams/                    ER diagram and relational schema
docs/PROJECT_CONTEXT.md           full design, rules, decisions and progress (start here)
docs/02_ddl_explained.md          why every table and constraint looks the way it does
docs/quickbite.dbml               DBML for dbdiagram.io, generated from 01_schema.sql
```

## Build progress

| Step | Rubric item (marks) | Status |
|---|---|---|
| 0 | ER diagram (2), relational schema (3) | done |
| 1 | Repo + Docker skeleton, Git from day one (part of 2) | done |
| 2 | DDL with constraints (4), DB roles (part of 4) | done: run and verified 6 Nov 2026 |
| 3 | Seed data + generator, DML (4) | done: 8 Nov 2026 (60,000 orders, 6 planted leaks) |
| 4 | Views + `fn_order_contribution` | next |
| 5 | Nested / correlated / recursive / join queries (4) | |
| 6 | Procedures, functions, triggers, CTEs (6) | |
| 7 | NoSQL creation (4), NoSQL feature + RUD (7), technology justification (1) | |
| 8 | Next.js UI (3), API integration (2), login + RBAC (4) | |
| 9 | Documentation, demo, viva prep (2 + 4) | |

## Core formulas

- **Revenue** = food subtotal × commission % + delivery fee + platform fee + packaging fee
- **Platform discount** = discount × (1 − restaurant_share_pct / 100)
- **Delivery cost** = partner payout + incentive + wait-time pay
- **Refund loss** = refund + compensation − recovered
- **Contribution** = revenue − platform discount − delivery cost − gateway fee − support cost − refund loss
- **Leak amount** = cost in excess of a benchmark (never the whole cost); the largest leak on an order is its **primary** leak.
