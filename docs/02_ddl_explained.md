# Step 2 explained: from relational schema to DDL

This note explains `db/mysql/01_schema.sql` and `db/mysql/02_roles.sql`. Read it with the relational schema diagram open (`docs/diagrams/QuickBite_Relational_Schema.pdf`). It is written so that either team member can answer viva questions about any table.

## 1. The idea in one paragraph

The ER diagram says *what* the data is. The relational schema says *which tables and keys* hold it. The DDL makes the database itself **refuse bad data**. Every rule you can state about the business ("a refund can't recover more than was refunded", "a cancelled order must say when it was cancelled") should become a constraint, so that no bug in the generator, the API or a manual INSERT can break it.

## 2. How each ER construct became DDL

| ER construct (diagram) | Mapping step | What it became in SQL | Example |
|---|---|---|---|
| Strong entity | 1 | `CREATE TABLE` with a surrogate `AUTO_INCREMENT` PK | `customer`, `restaurant` |
| Key attribute (underlined) | 1 | `PRIMARY KEY` | `pk_customer` |
| Other unique attribute (plain oval, unique in reality) | 1 | `UNIQUE` | `uq_customer_email`, `uq_coupon_code` |
| Composite attribute | 1 | only its leaf columns | `Fees` → `delivery_fee`, `platform_fee`, `packaging_fee` |
| Derived attribute (dashed oval) | rule | **no column**; computed later in a view or function | `food_subtotal`, `GMV`, `delay_minutes`, `contribution_amount` |
| Weak entity `ORDER_COST` | 2 | PK = owner's PK (no partial key), FK `ON DELETE CASCADE` | `order_cost(order_id, support_cost)` |
| 1:1 `FULFILLED_BY` | 3a | FK on the total side, `NOT NULL` + `UNIQUE` | `delivery_trip.order_id` |
| 1:N | 4 | FK in the N-side table | `orders.restaurant_id` |
| Recursive 1:N | 4 | self-FK | `customer.referred_by_customer_id`, `region.parent_region_id` |
| M:N | 5 | new table, PK = both FKs, plus diamond attributes | `order_item`, `discount_usage` |
| Total participation | rule | FK is `NOT NULL` | `orders.customer_id` |
| Partial participation | rule | FK is `NULL`able | `coupon.campaign_id`, `leakage_record.leak_rule_id` |

Steps 6 (multivalued) and 7 (n-ary) are not used: the diagram has no double ovals and no ternary diamonds.

## 3. The five kinds of constraint, with where to find them

1. **PRIMARY KEY**: one per table, always named `pk_<table>`. Composite in `order_item` and `discount_usage`.
2. **FOREIGN KEY**: 26 of them, one per arrow in the schema diagram, named `fk_<table>_<what>`. InnoDB creates an index on every FK column automatically, which is why most FK columns have no explicit index.
3. **UNIQUE**: candidate keys (`email`, `coupon_code`, `leak_name`, `role_name`) and business rules such as "no two menu items with the same name in one restaurant" (`uq_menu_item_name`).
4. **NOT NULL / DEFAULT**: from participation, plus sensible defaults (`order_status = 'PLACED'`, money columns `0`, timestamps `CURRENT_TIMESTAMP`).
5. **CHECK** (47 named checks): enforced by MySQL since 8.0.16. Three kinds are used:
   - **Ranges:** `commission_pct BETWEEN 0 AND 100`, `quantity BETWEEN 1 AND 50`.
   - **Allowed values:** `order_status IN (...)`. This replaces ENUM, so the allowed list is a visible, named constraint.
   - **Cross-column rules** (the interesting ones for the viva):
     - `chk_orders_cancel_consistent`: a cancellation stage exists *if and only if* the status is CANCELLED.
     - `chk_refund_recovered_le_refund`: recovered money cannot exceed the refund.
     - `chk_trip_deliver_after_pickup`: timestamps must be in order.
     - `chk_coupon_share`: ties `restaurant_share_pct` to `funded_by` (see section 5).
     - `chk_reco_target_id`: a GLOBAL recommendation has no target; every other kind must have one.

## 4. ON DELETE: why each choice

| Rule | Used for | Reason |
|---|---|---|
| `CASCADE` | `order_cost`, `order_item`, `discount_usage`, `delivery_trip`, `leakage_record` | They describe a single order and mean nothing without it. For `order_cost` this is the textbook rule for a weak entity. |
| `RESTRICT` | payments, refunds, compensation; master data (city, restaurant, customer) | Money history must never disappear as a side effect. You must deal with it explicitly first. |
| `SET NULL` | `coupon.campaign_id`, `leakage_record.leak_rule_id`, `recommendation.leak_type_id`, `audit_log.actor_user_id`, both self-FKs | The relationship was partial anyway, so the row stays valid without the link. |

So an order **with** a payment cannot be deleted (RESTRICT wins), while a test order with no payment takes its cost row, items and leaks with it. The constraint test file demonstrates exactly this.

## 5. Design details worth explaining in the viva

- **Money is `DECIMAL(10,2)`**, never FLOAT. FLOAT cannot store 0.10 exactly, and profit totals over 60k orders would drift.
- **One discount formula for all funders.** `chk_coupon_share` forces PLATFORM → 0, RESTAURANT → 100, SHARED → strictly between 0 and 100. That means the platform's cost of a discount is always `discount_amount × (1 − restaurant_share_pct / 100)`, with no CASE needed. It gives exactly the same results as the formula doc.
- **`unit_price` in `order_item` is not redundant** with `menu_item.list_price`. It is the price at the moment of ordering (a relationship attribute), and list prices change over time.
- **One primary leak per order per run.** This is a *functional* unique index:
  `UNIQUE (order_id, detection_run_id, (IF(is_primary, 1, NULL)))`.
  Non-primary rows produce NULL, and a UNIQUE index allows any number of NULLs, so only primary rows compete. This is MySQL's way of writing a partial unique index.
- **Polymorphic `recommendation.target_id`** can point at a restaurant, a city, a coupon and so on, so it cannot be a FK. A trigger will validate it in Step 6.
- **Self-referral is not a CHECK.** `referred_by_customer_id <> customer_id` looks like an obvious CHECK, but MySQL forbids CHECK constraints that use an AUTO_INCREMENT column. A trigger handles it in Step 6. This is a good example of choosing a trigger *because* a constraint can't do the job.
- **3NF note:** `leakage_record.leak_type_id` is functionally determined by `leak_rule_id` when a rule exists. It is kept because `leak_rule_id` is nullable: manually logged leaks have a type but no rule.

## 6. RBAC inside the database (`02_roles.sql`)

| MySQL role | Can do | Cannot do |
|---|---|---|
| `qb_admin` | everything on `quickbite.*` | grant rights to others |
| `qb_analyst` | read all business tables; insert/update `leak_rule`; update **only the `status` column** of `recommendation` | read `app_user.password_hash`; change recommendation numbers; edit leak types (granted, then REVOKEd) |
| `qb_viewer` | read dashboard tables; read `customer` **only** for `customer_id`, `referred_by_customer_id`, `created_at` | see names, emails or phones; see payments or refunds; change anything |

Three ideas to explain:
1. **Role vs user.** A role is a named bundle of privileges; a user logs in. `GRANT qb_viewer TO 'qb_viewer_user'` plus `SET DEFAULT ROLE ALL` activates it on every login.
2. **Column-level privileges** (`GRANT SELECT (col1, col2) ON t`) hide personal data without needing a separate view.
3. **Defence in depth.** The app checks `app_user.role_id` before showing a page, *and* the API connects to MySQL as the matching role. If the app check is ever wrong, MySQL still refuses.

## 7. How to run and check it

```bash
cp .env.example .env              # then set MYSQL_ROOT_PASSWORD
docker compose up -d              # first start runs 01_schema.sql, then 02_roles.sql
docker compose ps                 # wait for "healthy"

# 23 tables?
docker compose exec mysql mysql -uroot -p -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='quickbite';"

# constraints reject bad data (each "EXPECT ERROR" line should error)
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --force quickbite' \
  < db/mysql/tests/constraint_tests.sql
```

Screenshot the constraint-test output for the report: it is direct evidence for the "DDL with constraints" marks.
