-- =====================================================================
--  QuickBite  -  constraint_tests.sql
--  Proves the DDL constraints work. Use it in the demo / viva.
--
--  Run with --force so the client keeps going after each expected error:
--    docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --force quickbite \
--      < db/mysql/tests/constraint_tests.sql
--
--  Every statement marked "EXPECT ERROR" must fail with the named constraint.
--  Everything runs inside a transaction that is rolled back at the end,
--  so the database is left unchanged.
-- =====================================================================
USE quickbite;
START TRANSACTION;

-- ---- minimal valid data (these MUST succeed) ----
INSERT INTO region (region_id, region_name, region_type) VALUES (900, 'Test Country', 'COUNTRY');
INSERT INTO city (city_id, region_id, city_name) VALUES (900, 900, 'Test City');
INSERT INTO customer (customer_id, full_name, email, phone) VALUES (900, 'Test User', 'test@example.com', '9876543210');
INSERT INTO restaurant (restaurant_id, city_id, restaurant_name, commission_pct) VALUES (900, 900, 'Test Kitchen', 18.00);
INSERT INTO menu_item (menu_item_id, restaurant_id, item_name, category, list_price) VALUES (900, 900, 'Test Dosa', 'MAINS', 120.00);
INSERT INTO delivery_partner (partner_id, city_id, partner_name) VALUES (900, 900, 'Test Rider');
INSERT INTO orders (order_id, customer_id, restaurant_id, order_time, distance_km) VALUES (900, 900, 900, NOW(), 3.5);
SELECT 'valid rows inserted' AS step;

-- ---- PRIMARY KEY ----
-- EXPECT ERROR: Duplicate entry '900' for key 'customer.PRIMARY'
INSERT INTO customer (customer_id, full_name, email, phone) VALUES (900, 'Dup', 'dup@example.com', '9876500000');
-- Composite PK from Step 5: the first line succeeds, the second is the same
-- (order, item) pair again.
INSERT INTO order_item VALUES (900, 900, 1, 120.00);
-- EXPECT ERROR: Duplicate entry '900-900' for key 'order_item.PRIMARY'
INSERT INTO order_item VALUES (900, 900, 2, 120.00);

-- ---- UNIQUE ----
-- EXPECT ERROR: uq_customer_email
INSERT INTO customer (full_name, email, phone) VALUES ('Other', 'test@example.com', '9876511111');

-- ---- FOREIGN KEY ----
-- EXPECT ERROR: fk_orders_customer (customer 99999 does not exist)
INSERT INTO orders (customer_id, restaurant_id, order_time, distance_km) VALUES (99999, 900, NOW(), 2);
-- EXPECT ERROR: fk_restaurant_city ... RESTRICT: a city with restaurants cannot be deleted
DELETE FROM city WHERE city_id = 900;

-- ---- NOT NULL ----
-- EXPECT ERROR: Column 'restaurant_id' cannot be null (total participation in RECEIVES)
INSERT INTO orders (customer_id, restaurant_id, order_time, distance_km) VALUES (900, NULL, NOW(), 2);

-- ---- CHECK ----
-- EXPECT ERROR: chk_restaurant_commission
UPDATE restaurant SET commission_pct = 150 WHERE restaurant_id = 900;
-- EXPECT ERROR: chk_orders_cancel_consistent (CANCELLED needs a stage)
UPDATE orders SET order_status = 'CANCELLED' WHERE order_id = 900;
-- EXPECT ERROR: chk_coupon_share (SHARED must have 0 < share < 100)
INSERT INTO coupon (coupon_code, discount_type, discount_value, funded_by, restaurant_share_pct)
VALUES ('BADSHARE', 'PERCENT', 20, 'SHARED', 0);
-- EXPECT ERROR: chk_coupon_value (a percentage above 100)
INSERT INTO coupon (coupon_code, discount_type, discount_value, funded_by) VALUES ('BADPCT', 'PERCENT', 120, 'PLATFORM');
-- EXPECT ERROR: chk_campaign_dates
INSERT INTO campaign (campaign_name, start_date, end_date) VALUES ('Backwards', '2026-05-10', '2026-05-01');
-- EXPECT ERROR: chk_refund_recovered_le_refund
INSERT INTO refund (order_id, refund_amount, recovered_amount, responsibility, refund_reason)
VALUES (900, 100, 150, 'RESTAURANT', 'MISSING_ITEM');
-- EXPECT ERROR: chk_trip_deliver_after_pickup
INSERT INTO delivery_trip (order_id, partner_id, assigned_at, picked_up_at, delivered_at,
                           promised_delivery_at, promised_prep_minutes)
VALUES (900, 900, '2026-05-01 12:00', '2026-05-01 12:20', '2026-05-01 12:10', '2026-05-01 12:45', 15);
-- EXPECT ERROR: chk_reco_target_id (a RESTAURANT recommendation needs a target_id)
INSERT INTO recommendation (target_type, target_id, recommendation_text, demand_risk, priority_score)
VALUES ('RESTAURANT', NULL, 'Cut free delivery', 'LOW', 50);

-- ---- JSON type ----
-- EXPECT ERROR: Invalid JSON text
INSERT INTO leak_type (leak_type_id, leak_name, description) VALUES (900, 'TEST_LEAK', 'test');
INSERT INTO leak_rule (leak_type_id, rule_name, threshold_value, rule_config) VALUES (900, 'bad json', 10, '{not json');

-- ---- functional unique index: one primary leak per order per run ----
INSERT INTO leakage_record (order_id, leak_type_id, leak_amount, is_primary, detection_run_id, explanation)
VALUES (900, 900, 25.00, TRUE, 'run-test', 'first primary: OK');
INSERT INTO leak_type (leak_type_id, leak_name, description) VALUES (901, 'TEST_LEAK_2', 'test');
-- EXPECT ERROR: uq_leakage_one_primary (a second primary leak on the same order and run)
INSERT INTO leakage_record (order_id, leak_type_id, leak_amount, is_primary, detection_run_id, explanation)
VALUES (900, 901, 10.00, TRUE, 'run-test', 'second primary: must fail');
-- but a second NON-primary leak is fine (NULL in the index)
INSERT INTO leakage_record (order_id, leak_type_id, leak_amount, is_primary, detection_run_id, explanation)
VALUES (900, 901, 10.00, FALSE, 'run-test', 'secondary: OK');

-- ---- ON DELETE CASCADE on the weak entity ----
INSERT INTO order_cost (order_id, support_cost) VALUES (900, 5.00);
SELECT COUNT(*) AS order_cost_rows_before FROM order_cost WHERE order_id = 900;   -- 1
DELETE FROM orders WHERE order_id = 900;      -- owner deleted (no payments, so RESTRICT does not block)
SELECT COUNT(*) AS order_cost_rows_after FROM order_cost WHERE order_id = 900;    -- 0: weak entity went with it

ROLLBACK;
SELECT 'all test data rolled back' AS step;
