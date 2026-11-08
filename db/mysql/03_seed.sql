-- =====================================================================
--  QuickBite  -  03_seed.sql
--  Reference ("master") data that everything else depends on
--  (rubric: DML - INSERT, INSERT ... SELECT, ON DUPLICATE KEY UPDATE)
--
--  What is here (small, hand-written, never random):
--    1. region      12 rows, a 3-level tree: COUNTRY -> ZONE -> STATE
--    2. city         9 rows (Kochi is inactive: launch planned, no restaurants)
--    3. leak_type    6 leak categories
--    4. leak_rule    9 detection rules with JSON settings (1 inactive)
--    5. app_user     3 web-app logins, one per app_role
--
--  What is NOT here: customers, restaurants, menus, partners, campaigns,
--  coupons and orders. The Python generator (generator/generate_data.py)
--  creates those, and it relies on the city_id values below.
--
--  Explicit ids are used so other scripts can refer to them (city 1 is
--  always Bengaluru). AUTO_INCREMENT accepts an explicit value and simply
--  continues after the highest one.
--
--  Re-runnable: every INSERT uses ON DUPLICATE KEY UPDATE, so running the
--  file twice updates the rows instead of failing on the primary key.
--  Runs automatically on an EMPTY volume (after 01 and 02). Otherwise apply it
--  by hand:
--    docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" quickbite' < db/mysql/03_seed.sql
-- =====================================================================
USE quickbite;

-- ---------------------------------------------------------------------
-- 1. REGION: recursive PART_OF (parent_region_id -> region_id)
--    Parents must exist before children (the self-FK is checked per row),
--    so rows are listed top-down: country, then zones, then states.
--    East Zone has no states yet: useful to show an outer join / leaf node.
-- ---------------------------------------------------------------------
INSERT INTO region (region_id, region_name, region_type, parent_region_id) VALUES
  ( 1, 'India',       'COUNTRY', NULL),
  ( 2, 'South Zone',  'ZONE',    1),
  ( 3, 'West Zone',   'ZONE',    1),
  ( 4, 'North Zone',  'ZONE',    1),
  ( 5, 'East Zone',   'ZONE',    1),
  ( 6, 'Karnataka',   'STATE',   2),
  ( 7, 'Tamil Nadu',  'STATE',   2),
  ( 8, 'Telangana',   'STATE',   2),
  ( 9, 'Kerala',      'STATE',   2),
  (10, 'Maharashtra', 'STATE',   3),
  (11, 'Delhi',       'STATE',   4),
  (12, 'Haryana',     'STATE',   4)
AS new_row
ON DUPLICATE KEY UPDATE
  region_name      = new_row.region_name,
  region_type      = new_row.region_type,
  parent_region_id = new_row.parent_region_id;

-- ---------------------------------------------------------------------
-- 2. CITY: LOCATED_IN (every city belongs to a STATE-level region)
--    timezone and is_active fall back to their DEFAULTs where omitted.
-- ---------------------------------------------------------------------
INSERT INTO city (city_id, region_id, city_name, timezone, is_active) VALUES
  (1,  6, 'Bengaluru', 'Asia/Kolkata', TRUE),
  (2,  6, 'Mysuru',    'Asia/Kolkata', TRUE),
  (3,  7, 'Chennai',   'Asia/Kolkata', TRUE),
  (4,  8, 'Hyderabad', 'Asia/Kolkata', TRUE),
  (5,  9, 'Kochi',     'Asia/Kolkata', FALSE),   -- not launched: no restaurants
  (6, 10, 'Mumbai',    'Asia/Kolkata', TRUE),
  (7, 10, 'Pune',      'Asia/Kolkata', TRUE),
  (8, 11, 'New Delhi', 'Asia/Kolkata', TRUE),
  (9, 12, 'Gurugram',  'Asia/Kolkata', TRUE)
AS new_row
ON DUPLICATE KEY UPDATE
  region_id = new_row.region_id,
  city_name = new_row.city_name,
  timezone  = new_row.timezone,
  is_active = new_row.is_active;

-- ---------------------------------------------------------------------
-- 3. LEAK_TYPE: the six ways an order can lose money.
--    Each one measures a cost IN EXCESS OF A BENCHMARK, never the whole cost.
--    The cost parts are split so two leak types never count the same rupee:
--      delay vouchers + wait-time pay -> DELAY_COST
--      all other refunds/compensation -> UNRECOVERED_REFUND
-- ---------------------------------------------------------------------
INSERT INTO leak_type (leak_type_id, leak_name, description, is_active) VALUES
  (1, 'DISCOUNT_OVERSPEND',
      'Platform-funded discount above the allowed share of the food subtotal, including stacked coupons.', TRUE),
  (2, 'DELIVERY_COST_OVERRUN',
      'Partner payout plus incentive above the expected cost for the trip distance.', TRUE),
  (3, 'DELAY_COST',
      'Wait-time pay and delay vouchers caused by slow preparation or late delivery.', TRUE),
  (4, 'UNRECOVERED_REFUND',
      'Refunds and compensation (except delay vouchers) not recovered from the responsible party.', TRUE),
  (5, 'GATEWAY_FEE_EXCESS',
      'Payment gateway fee above the benchmark rate.', TRUE),
  (6, 'LOW_VALUE_ORDER',
      'Small baskets whose revenue cannot cover the fixed cost of delivering them.', TRUE)
AS new_row
ON DUPLICATE KEY UPDATE
  leak_name   = new_row.leak_name,
  description = new_row.description,
  is_active   = new_row.is_active;

-- ---------------------------------------------------------------------
-- 4. LEAK_RULE: DEFINES (LEAK_TYPE 1 : N). threshold_value is the number an
--    analyst tunes most often; rule_config (JSON) holds the rest of the
--    benchmark. MySQL rejects the row if the JSON is not valid.
--    Type 1 and type 2 each have two rules (that is the "N" in 1:N).
--    Rule 9 is retired (is_active = FALSE) but kept for history.
-- ---------------------------------------------------------------------
INSERT INTO leak_rule (leak_rule_id, leak_type_id, rule_name, threshold_value, rule_config, is_active) VALUES
  (1, 1, 'Discount above 15% of subtotal', 15.00,
      '{"metric": "platform_discount_pct_of_subtotal", "benchmark_pct": 15}', TRUE),
  (2, 1, 'Coupon stacking', 1.00,
      '{"metric": "coupons_per_order", "max_coupons": 1, "leak": "platform discount of every coupon after the largest"}', TRUE),
  (3, 2, 'Delivery overrun - normal conditions', 10.00,
      '{"base_pay": 25, "per_km": 7, "tolerance_pct": 10, "applies_when": "not peak and not rainy"}', TRUE),
  (4, 2, 'Delivery overrun - peak or rain', 25.00,
      '{"base_pay": 25, "per_km": 7, "tolerance_pct": 25, "applies_when": "peak or rainy"}', TRUE),
  (5, 3, 'Late delivery beyond 10 minutes', 10.00,
      '{"metric": "delay_minutes", "grace_minutes": 10, "cost_parts": ["wait_time_pay", "DELAY_VOUCHER compensation"]}', TRUE),
  (6, 4, 'Any unrecovered refund', 0.00,
      '{"counted_refund_status": ["APPROVED", "PROCESSED"], "excluded_compensation": ["DELAY_VOUCHER"]}', TRUE),
  (7, 5, 'Gateway fee above 2%', 2.00,
      '{"metric": "gateway_fee_pct_of_amount", "benchmark_pct": 2.0, "payment_status": "SUCCESS"}', TRUE),
  (8, 6, 'Basket below 149', 149.00,
      '{"metric": "food_subtotal", "max_subtotal": 149, "leak": "negative contribution of the order"}', TRUE),
  (9, 2, 'Delivery overrun - flat 60 cap (retired)', 60.00,
      '{"max_delivery_cost": 60, "retired_reason": "replaced by distance-based rules 3 and 4"}', FALSE)
AS new_row
ON DUPLICATE KEY UPDATE
  leak_type_id    = new_row.leak_type_id,
  rule_name       = new_row.rule_name,
  threshold_value = new_row.threshold_value,
  rule_config     = new_row.rule_config,
  is_active       = new_row.is_active;

-- ---------------------------------------------------------------------
-- 5. APP_USER: one web-app login per role (HAS_ROLE, APP_ROLE 1 : N).
--    INSERT ... SELECT looks the role_id up by name instead of guessing it.
--    password_hash is bcrypt, made with generator/hash_password.py.
--    DEVELOPMENT passwords (change before any real deployment):
--      admin@quickbite.dev   / Admin@App123
--      analyst@quickbite.dev / Analyst@App123
--      viewer@quickbite.dev  / Viewer@App123
-- ---------------------------------------------------------------------
INSERT INTO app_user (role_id, full_name, email, password_hash)
SELECT r.role_id, u.full_name, u.email, u.password_hash
FROM (
  SELECT 'ADMIN' AS role_name, 'Asha Admin' AS full_name, 'admin@quickbite.dev' AS email,
         '$2a$10$LiNYp/fCHHwwVqcdMgn1y.V5ntapwvRz2/DBFKtXPNbgcXINWPaYO' AS password_hash
  UNION ALL
  SELECT 'ANALYST', 'Arjun Analyst', 'analyst@quickbite.dev',
         '$2a$10$yEkVkwYAFjpGUVOF/gFRnu.fz5kv6QUwTtJ62iOOLfb2Gz5ClHX6.'
  UNION ALL
  SELECT 'VIEWER', 'Vani Viewer', 'viewer@quickbite.dev',
         '$2a$10$ysl7lYTV0XUVq3Oyk4b/CO9nIZAtwhKp6.TfPkQBcEHxESN1r0qIK'
) AS u
JOIN app_role AS r ON r.role_name = u.role_name
ON DUPLICATE KEY UPDATE                        -- uq_app_user_email decides "duplicate"
  role_id       = r.role_id,                   -- (INSERT ... SELECT may name the
  full_name     = u.full_name,                 --  SELECT's columns directly)
  password_hash = u.password_hash;

-- Quick check (expected: 12, 9, 6, 9, 3)
SELECT (SELECT COUNT(*) FROM region)    AS regions,
       (SELECT COUNT(*) FROM city)      AS cities,
       (SELECT COUNT(*) FROM leak_type) AS leak_types,
       (SELECT COUNT(*) FROM leak_rule) AS leak_rules,
       (SELECT COUNT(*) FROM app_user)  AS app_users;
