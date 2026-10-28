# QuickBite DBMS Mini Project: Project Context

> **For Claude (project knowledge):** this file replaces `QuickBite_Chat_Handoff.md`.
> - Sections 3 and 4 are the course rules. Follow them strictly.
> - Section 5 is the **frozen design**; `db/mysql/01_schema.sql` is the **source of truth** for table and column names, types and constraints. Don't change either without asking.
> - Section 6 lists the rules the data generator, queries and API must respect.
> - Section 8 says what is done and what comes next.

Last updated: Mon 26 Oct 2026, after Steps 1 and 2 were written.

---

## 1. Project in brief

**QuickBite Profit Leakage Analyzer**: DBMS mini project, PES University UE24CS351A, Experiential Learning Level 3, 50 marks, team of 2.

- **Problem:** orders and revenue grow while net profit falls. The system computes **contribution per order**, finds **where, why and how much** profit leaks (discounts, delivery cost, refunds, delays, low-value segments), and produces ranked **recommendations** with an estimated saving and demand risk.
- **Stack:** MySQL 8.4 (source of truth); MongoDB 7 (`order_events`, `feedback`, `leak_notes` with full CRUD, `saved_scenarios`); Redis 7 (KPI and leaderboard cache); Next.js (UI + API routes); everything in one `docker-compose.yml`.
- **Data:** about 60,000 generated orders over 12 months, with planted leaks.

### Rubric (50 marks)

| # | Criterion | Marks |
|---|---|---|
| 1 | ER diagram (2), relational schema with keys, relationships, constraints (3) | 5 |
| 2 | SQL DDL with constraints (4), NoSQL database creation (4), technology justification (1) | 9 |
| 3 | DML (4), nested / correlated / recursive / join queries (4) | 8 |
| 4 | Procedures/functions, triggers, CTEs (6), NoSQL feature with RUD (7) | 13 |
| 5 | Next.js interface (3), backend/API and DB integration (2) | 5 |
| 6 | Authentication (frontend) + at least two roles + RBAC in the database | 4 |
| 7 | Documentation, Git/GitHub (2), originality and individual contribution (4) | 6 |

### Formulas (locked)

- **Food subtotal** = Σ quantity × unit_price (from `order_item`)
- **GMV** = food subtotal + delivery_fee + platform_fee + packaging_fee
- **Revenue** = food subtotal × commission_pct/100 + delivery_fee + platform_fee + packaging_fee
- **Platform-borne discount** = discount_amount × (1 − restaurant_share_pct/100). The schema pins `restaurant_share_pct` to 0 for PLATFORM, 100 for RESTAURANT, strictly between for SHARED, so this one formula covers all three.
- **Delivery cost** = partner_payout + incentive_amount + wait_time_pay
- **Unrecovered refund loss** = Σ refund_amount + Σ compensation_amount − Σ recovered_amount
- **Contribution** = Revenue − platform discount − delivery cost − gateway fee − support cost − unrecovered refund loss
- **Delay minutes** = delivered_at − promised_delivery_at
- **Leak amount** = cost in excess of a benchmark, never the whole cost. The **primary leak** is the largest leak on an order.
- **Reconciliation:** the sum of primary leaks on loss-making orders must not exceed their total loss.

Worked example (one order, used in the team guide): subtotal 280, commission 18%, fees 30+5+10, delivery cost 60, gateway fee 6.50 → revenue 95.40, contribution 28.90.

---

## 2. Team and workflow

| Step | Work | Owner |
|---|---|---|
| 0 | ER diagram, relational schema | done |
| 1 | GitHub repo, Docker on both laptops | A creates repo; B clones and checks Docker |
| 2 | Run DDL, constraint tests, DB roles | A |
| 3 | Python data generator (~60k orders, planted leaks) | B |
| 3 | Seed file (regions, cities, leak types, leak rules), DML demo script | A |
| 4 | Views + `fn_order_contribution` | A |
| 5 | Nested, correlated, recursive, join queries | A |
| 6 | Procedures, functions, triggers, CTEs | A |
| 7 | MongoDB collections + leak notes CRUD, Redis cache, technology justification | B |
| 8 | Next.js pages and API routes, login | B |
| 8 | API role checks tied to MySQL roles | A and B |
| 9 | Report, demo script, viva practice | both |

Workflow: one branch per task, pull request, the other person reviews and explains it back before merging. Daily 20-minute teach-back. Both use VS Code with Git Bash (Windows) and Docker Desktop. Each person has their own Claude Project with this file and the repo as knowledge, synced from GitHub after each merge.

---

## 3. ER diagram rules (course slides, Elmasri & Navathe; follow strictly)

**Chen notation**, cardinality written as **1 / N / M on the lines**.

| Construct | Symbol |
|---|---|
| Strong entity | Rectangle, name in CAPS |
| Weak entity | Double rectangle |
| Relationship | Diamond (verb name) |
| Identifying relationship | Double diamond |
| Simple attribute | Oval |
| Key attribute | Oval, name underlined. Only the chosen PK is underlined; other unique attributes are plain. |
| Partial key of a weak entity | Oval with dashed underline |
| Multivalued attribute | Double oval |
| Composite attribute | Oval with component ovals |
| Derived attribute | Dashed oval; not stored |
| Relationship attribute | Oval attached to the diamond |
| Total participation | Double line |
| Partial participation | Single line |
| Recursive relationship | Same entity twice on one diamond, lines labelled with role names |

Design rules:
1. Every strong entity has a key attribute.
2. A weak entity has no key of its own; it is identified by its owner plus its partial key (if any), has total participation in the identifying relationship, and the owner is on the 1 side.
3. Attributes of the association go on the diamond.
4. Use a ternary relationship only when binary ones can't capture the fact.
5. Foreign keys are never drawn as attributes.
6. Every relationship line shows cardinality and participation.
7. Don't store a value twice, and don't add a relationship that duplicates an existing path.

---

## 4. ER-to-relational mapping (7 steps from the slides)

1. **Strong entity** → relation with all simple attributes; composite attributes contribute their leaves; one key is the PK, other keys are UNIQUE.
2. **Weak entity** → relation with the owner's PK as FK; PK = owner PK + partial key.
3. **Binary 1:1** → (a) FK on the total-participation side with UNIQUE (preferred), (b) merge, or (c) cross-reference relation.
4. **Binary 1:N** → FK in the N side plus the relationship's attributes; recursive → self-FK.
5. **Binary M:N** → new relation; PK = both FKs; plus the relationship's attributes.
6. **Multivalued attribute** → new relation (owner PK, value), both together the PK.
7. **n-ary** → new relation with all participating PKs as FKs.

Derived attributes are not stored. Total participation on the N side → NOT NULL FK; partial → nullable FK.

---

## 5. Frozen design

Diagrams: `docs/diagrams/QuickBite_ER_Diagram.pdf` and `docs/diagrams/QuickBite_Relational_Schema.pdf`. DBML for dbdiagram.io: `docs/quickbite.dbml` (generated from the SQL).

### 5.1 Entities (21)

| Entity | Attributes ([PK]; composite in brackets; *derived* in italics) |
|---|---|
| CUSTOMER | customer_id [PK], full_name, email, phone, created_at |
| REGION | region_id [PK], region_name, region_type |
| CITY | city_id [PK], city_name, timezone, is_active |
| RESTAURANT | restaurant_id [PK], restaurant_name, commission_pct, is_active, created_at |
| MENU_ITEM | menu_item_id [PK], item_name, category, list_price, is_available |
| DELIVERY_PARTNER | partner_id [PK], partner_name, is_active |
| ORDER | order_id [PK], order_time, order_status, Fees(delivery_fee, platform_fee, packaging_fee), distance_km, is_peak_period, is_rainy_weather, cancellation_stage, *food_subtotal*, *GMV* |
| DELIVERY_TRIP | trip_id [PK], Timeline(assigned_at, picked_up_at, delivered_at, promised_delivery_at), Prep_time(promised_prep_minutes, actual_prep_minutes), Delivery_cost(partner_payout, incentive_amount, wait_time_pay), *delay_minutes* |
| CAMPAIGN | campaign_id [PK], campaign_name, is_active, Validity(start_date, end_date) |
| COUPON | coupon_id [PK], coupon_code, Discount(discount_type, discount_value, max_discount_amount), funded_by, restaurant_share_pct, free_delivery, minimum_basket_amount |
| ORDER_COST (**weak**, owner ORDER, no partial key) | support_cost, *platform_discount_amount*, *refund_loss_amount*, *contribution_amount* |
| PAYMENT_TRANSACTION | payment_id [PK], gateway_name, payment_status, transaction_amount, gateway_fee, transaction_time |
| REFUND | refund_id [PK], refund_amount, recovered_amount, responsibility, refund_reason, refund_status, created_at |
| COMPENSATION | compensation_id [PK], compensation_amount, reason, created_at |
| LEAK_TYPE | leak_type_id [PK], leak_name, description, is_active |
| LEAK_RULE | leak_rule_id [PK], rule_name, threshold_value, rule_config, is_active, updated_at |
| LEAKAGE_RECORD | leakage_record_id [PK], leak_amount, is_primary, detected_at, detection_run_id, explanation |
| RECOMMENDATION | recommendation_id [PK], recommendation_text, Target(target_type, target_id), estimated_saving, demand_risk, priority_score, status, created_at |
| APP_ROLE | role_id [PK], role_name, description |
| APP_USER | user_id [PK], email, full_name, password_hash, is_active, created_at |
| AUDIT_LOG | audit_log_id [PK], entity_name, entity_id, action_name, old_values, new_values, created_at |

### 5.2 Relationships (24)

| Relationship | Ends (TOTAL = double line on that side) | On the diamond |
|---|---|---|
| REFERS (recursive) | CUSTOMER Referrer 1 : Referee N, both partial | |
| PART_OF (recursive) | REGION Parent 1 : Child N, both partial | |
| LOCATED_IN | REGION 1 : CITY N TOTAL | |
| HOSTS | CITY 1 : RESTAURANT N TOTAL | |
| OFFERS | RESTAURANT 1 : MENU_ITEM N TOTAL | |
| BASED_IN | CITY 1 : DELIVERY_PARTNER N TOTAL | |
| PLACES | CUSTOMER 1 : ORDER N TOTAL | |
| RECEIVES | RESTAURANT 1 : ORDER N TOTAL | |
| CONTAINS | ORDER M TOTAL : MENU_ITEM N | quantity, unit_price |
| FULFILLED_BY | ORDER 1 : DELIVERY_TRIP 1 TOTAL | |
| ASSIGNED_TO | DELIVERY_PARTNER 1 : DELIVERY_TRIP N TOTAL | |
| APPLIES | ORDER M : COUPON N, both partial | discount_amount, used_at |
| ISSUES | CAMPAIGN 1 : COUPON N, both partial | |
| HAS_COST (identifying) | ORDER 1 : ORDER_COST 1 TOTAL | |
| PAID_VIA | ORDER 1 : PAYMENT_TRANSACTION N TOTAL | |
| REFUNDED_IN | ORDER 1 : REFUND N TOTAL | |
| COMPENSATED_BY | ORDER 1 : COMPENSATION N TOTAL | |
| HAS_LEAK | ORDER 1 : LEAKAGE_RECORD N TOTAL | |
| CLASSIFIES | LEAK_TYPE 1 : LEAKAGE_RECORD N TOTAL | |
| DETECTED_BY | LEAK_RULE 1 : LEAKAGE_RECORD N, partial | |
| DEFINES | LEAK_TYPE 1 : LEAK_RULE N TOTAL | |
| ADDRESSES | LEAK_TYPE 1 : RECOMMENDATION N, partial | |
| HAS_ROLE | APP_ROLE 1 : APP_USER N TOTAL | |
| PERFORMS | APP_USER 1 : AUDIT_LOG N, partial | |

### 5.3 Relations (23) and where each came from

| Relation | Mapping | Foreign keys (nullable marked) |
|---|---|---|
| region | Step 1, Step 4 recursive | parent_region_id → region (nullable) |
| city | Step 1, Step 4 | region_id → region |
| customer | Step 1, Step 4 recursive | referred_by_customer_id → customer (nullable) |
| restaurant | Step 1, Step 4 | city_id → city |
| menu_item | Step 1, Step 4 | restaurant_id → restaurant |
| delivery_partner | Step 1, Step 4 | city_id → city |
| orders | Step 1, Step 4 (named ORDERS: ORDER is reserved; no city_id, city comes via restaurant) | customer_id, restaurant_id |
| order_item | Step 5 from CONTAINS, PK (order_id, menu_item_id) | order_id, menu_item_id |
| order_cost | Step 2 weak entity, PK order_id | order_id → orders (CASCADE) |
| delivery_trip | Step 3a, order_id NOT NULL UNIQUE | order_id, partner_id |
| payment_transaction, refund, compensation | Step 4 | order_id |
| campaign | Step 1 | none |
| coupon | Step 1, Step 4 | campaign_id → campaign (nullable) |
| discount_usage | Step 5 from APPLIES, PK (order_id, coupon_id) | order_id, coupon_id |
| leak_type | Step 1 | none |
| leak_rule | Step 1, Step 4 | leak_type_id |
| leakage_record | Step 1, Step 4 ×3 | order_id, leak_type_id, leak_rule_id (nullable) |
| recommendation | Step 1, Step 4; target_id polymorphic, validated by trigger, not a FK | leak_type_id (nullable) |
| app_role | Step 1 | none |
| app_user | Step 1, Step 4 | role_id |
| audit_log | Step 1, Step 4 | actor_user_id (nullable) |

Steps 6 and 7 don't apply (no multivalued attributes, no n-ary relationships). 26 foreign keys in total.

---

## 6. Implementation decisions made in Step 2 (everything must respect these)

**Types.** Money is `DECIMAL(10,2)` (12,2 for estimated_saving). `order_id` and other high-volume IDs are `BIGINT UNSIGNED`. Booleans are `BOOLEAN`. `leak_rule.rule_config`, `audit_log.old_values/new_values` are `JSON`.

**Allowed values (CHECK constraints). The generator and API must use exactly these:**

| Column | Allowed values |
|---|---|
| region.region_type | COUNTRY, STATE, ZONE |
| orders.order_status | PLACED, ACCEPTED, PREPARING, PICKED_UP, DELIVERED, CANCELLED |
| orders.cancellation_stage | BEFORE_ACCEPT, AFTER_ACCEPT, AFTER_PICKUP; set **only** when status = CANCELLED, otherwise NULL |
| payment_transaction.payment_status | PENDING, SUCCESS, FAILED, REVERSED |
| payment_transaction.gateway_name | RAZORPAY, PAYU, CASHFREE, UPI_DIRECT, COD |
| refund.responsibility | RESTAURANT, PARTNER, PLATFORM, CUSTOMER |
| refund.refund_reason | LATE_DELIVERY, MISSING_ITEM, WRONG_ITEM, QUALITY, CANCELLED, OTHER |
| refund.refund_status | REQUESTED, APPROVED, REJECTED, PROCESSED |
| compensation.reason | DELAY_VOUCHER, GOODWILL, SERVICE_FAILURE, OTHER |
| coupon.discount_type | FLAT, PERCENT (PERCENT value ≤ 100) |
| coupon.funded_by + restaurant_share_pct | PLATFORM → 0; RESTAURANT → 100; SHARED → strictly between 0 and 100 |
| recommendation.target_type | GLOBAL, REGION, CITY, RESTAURANT, COUPON, CAMPAIGN, DELIVERY_PARTNER; target_id is NULL **only** for GLOBAL |
| recommendation.demand_risk | LOW, MEDIUM, HIGH |
| recommendation.status | NEW, ACCEPTED, REJECTED, IMPLEMENTED |
| app_role.role_name | ADMIN, ANALYST, VIEWER |
| audit_log.action_name | INSERT, UPDATE, DELETE, LOGIN, RUN |

**Ranges and cross-column rules:** commission_pct 0–100; distance_km 0–50; quantity 1–50; all fees and costs ≥ 0; gateway_fee ≤ transaction_amount; recovered_amount ≤ refund_amount; campaign end_date ≥ start_date; trip times in order (picked_up ≥ assigned, delivered ≥ picked_up, promised_delivery > assigned); customer email must look like an email and phone 10–15 digits; password_hash at least 50 characters (bcrypt).

**Uniqueness beyond PKs:** customer.email, app_user.email, coupon.coupon_code, leak_type.leak_name, leak_rule.rule_name, region.region_name, campaign.campaign_name, app_role.role_name; (region_id, city_name); (city_id, restaurant_name); (restaurant_id, item_name); delivery_trip.order_id; leakage_record (order_id, leak_type_id, detection_run_id); and a functional unique index allowing **one primary leak per order per detection run**.

**ON DELETE:** CASCADE for order_cost, order_item, discount_usage, delivery_trip, leakage_record; RESTRICT for money tables and master data; SET NULL for every nullable FK.

**Moved to triggers (Step 6) because a CHECK can't do it:** a customer can't refer themselves (MySQL forbids CHECK on AUTO_INCREMENT columns); recommendation.target_id must exist in the table named by target_type.

**Database roles (`02_roles.sql`):** `qb_admin` (all on quickbite), `qb_analyst` (SELECT on business tables, column-level SELECT on app_user without password_hash, INSERT/UPDATE on leak_rule, column-level UPDATE(status) on recommendation; UPDATE on leak_type granted then REVOKEd), `qb_viewer` (SELECT on dashboard tables, column-level SELECT on customer: customer_id, referred_by_customer_id, created_at only). Login accounts `qb_admin_user`, `qb_analyst_user`, `qb_viewer_user` (dev passwords in `.env.example`). The Next.js API will keep one connection pool per account and choose it from the logged-in user's app_role. Views and procedures will get their own GRANTs in the files that create them.

**Open 3NF note for the viva:** leakage_record.leak_type_id is determined by leak_rule_id when a rule exists; kept because leak_rule_id is nullable (manually logged leaks have no rule).

---

## 7. Repository layout

```
docker-compose.yml          MySQL 8.4, MongoDB 7, Redis 7 (+ Next.js under profile "app")
.env.example                copy to .env; never commit .env
db/mysql/01_schema.sql      23 tables, all constraints (runs first on an empty volume)
db/mysql/02_roles.sql       MySQL roles, login accounts, app_role rows
db/mysql/tests/constraint_tests.sql   16 statements that must fail; run with --force
db/mongo/                   Step 7
docs/PROJECT_CONTEXT.md     this file
docs/02_ddl_explained.md    teaching notes for the DDL and roles
docs/quickbite.dbml         DBML for dbdiagram.io, generated from 01_schema.sql
docs/diagrams/              ER diagram and relational schema PDFs
```

MySQL runs `db/mysql/*.sql` in name order only on the first start with an empty volume; after editing them, run `docker compose down -v` then `docker compose up -d`. New SQL files continue the numbering: `03_seed.sql`, `04_views.sql`, and so on.

---

## 8. Progress log and next steps

| Date | What happened |
|---|---|
| 24–25 Oct 2026 | ER diagram and relational schema finalised after two review rounds |
| 26 Oct 2026 | ORDER_COST kept as weak entity. Steps 1–2 files written (compose, DDL, roles, constraint tests, teaching notes, DBML). Team guide written. Not yet run against a real MySQL. |
| 26 Oct 2026 (evening) | Person A starts Step 1: GitHub repo |
| 27 Oct 2026 (planned) | Person A: Step 2, run the database, constraint tests, role tests |

**Next:** Step 3. Person A writes `03_seed.sql` (regions, cities, leak types, leak rules) and a DML demo script; Person B writes the generator, which needs the seed data first.

**Still open:** real submission and viva dates; final API route names.
