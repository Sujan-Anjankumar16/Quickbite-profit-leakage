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

On first start MySQL runs every file in `db/mysql/` in name order. To start again from an empty database: `docker compose down -v && docker compose up -d`.

## Repository layout

```
db/mysql/01_schema.sql            23 tables with all constraints (DDL)
db/mysql/02_roles.sql             MySQL roles qb_admin / qb_analyst / qb_viewer
db/mysql/tests/constraint_tests.sql   proves every kind of constraint rejects bad data
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
| 2 | DDL with constraints (4), DB roles (part of 4) | done: run and test it |
| 3 | Seed data + generator, DML (4) | next |
| 4 | Views + `fn_order_contribution` | |
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
