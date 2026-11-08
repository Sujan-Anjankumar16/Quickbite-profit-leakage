-- =====================================================================
--  QuickBite  -  demo/dml_demo.sql
--  DML demonstration (rubric item 3: "DML", 4 marks)
--
--  Covers: INSERT (single, multi-row, INSERT ... SELECT, upsert),
--          UPDATE (single row, with JOIN, with subquery + CASE, JSON),
--          DELETE (CASCADE, RESTRICT, subquery, multi-table JOIN),
--          transactions: START TRANSACTION, SAVEPOINT, ROLLBACK.
--
--  The whole script is ONE transaction that ends in ROLLBACK, so it leaves
--  the database exactly as it found it and can be run again and again.
--  Two statements are EXPECTED to fail (marked EXPECT ERROR), to show the
--  constraints also guard UPDATE and DELETE. Run with --force so the
--  client carries on after them:
--
--    docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --force -t quickbite' < db/mysql/demo/dml_demo.sql
--
--  Needs 03_seed.sql and the generated data to be loaded.
-- =====================================================================
USE quickbite;

SELECT COUNT(*) AS orders_before_demo FROM orders;

START TRANSACTION;

-- ---------------------------------------------------------------------
-- 1. INSERT one row, letting DEFAULTs fill the rest
--    created_at is omitted -> DEFAULT CURRENT_TIMESTAMP.
--    LAST_INSERT_ID() returns the AUTO_INCREMENT id just given out.
-- ---------------------------------------------------------------------
INSERT INTO customer (full_name, email, phone, referred_by_customer_id)
VALUES ('Demo Customer', 'demo.customer@example.com', '9876543210', 1);
SET @cust = LAST_INSERT_ID();

-- ---------------------------------------------------------------------
-- 2. Multi-row INSERT: a new restaurant and its menu in two statements
--    (city looked up by name with a scalar subquery, not a magic number)
-- ---------------------------------------------------------------------
INSERT INTO restaurant (city_id, restaurant_name, commission_pct)
VALUES ((SELECT city_id FROM city WHERE city_name = 'Bengaluru'), 'Demo Darshini', 18.00);
SET @rest = LAST_INSERT_ID();

INSERT INTO menu_item (restaurant_id, item_name, category, list_price) VALUES
  (@rest, 'Masala Dosa',   'Main Course', 110.00),
  (@rest, 'Filter Coffee', 'Beverage',     60.00),
  (@rest, 'Kesari Bath',   'Dessert',      55.00);

SELECT customer_id, full_name, created_at FROM customer WHERE customer_id = @cust;
SELECT menu_item_id, item_name, list_price FROM menu_item WHERE restaurant_id = @rest;

-- ---------------------------------------------------------------------
-- 3. One complete order = rows in five tables, in parent-first order.
--    This is the team guide's worked example:
--      subtotal 280 (2 x 110 + 1 x 60), commission 18%, fees 30 + 5 + 10,
--      delivery cost 60, gateway fee 6.50  ->  revenue 95.40, contribution 28.90
-- ---------------------------------------------------------------------
INSERT INTO orders (customer_id, restaurant_id, order_time, delivery_fee, platform_fee,
                    packaging_fee, distance_km)
VALUES (@cust, @rest, NOW(), 30.00, 5.00, 10.00, 3.50);       -- order_status DEFAULT 'PLACED'
SET @oid = LAST_INSERT_ID();

-- INSERT ... SELECT: copy today's list price into unit_price (price at order time)
INSERT INTO order_item (order_id, menu_item_id, quantity, unit_price)
SELECT @oid, menu_item_id,
       CASE item_name WHEN 'Masala Dosa' THEN 2 ELSE 1 END,
       list_price
FROM menu_item
WHERE restaurant_id = @rest AND item_name IN ('Masala Dosa', 'Filter Coffee');

INSERT INTO order_cost (order_id) VALUES (@oid);              -- support_cost DEFAULT 0

INSERT INTO payment_transaction (order_id, gateway_name, payment_status,
                                 transaction_amount, gateway_fee, transaction_time)
VALUES (@oid, 'RAZORPAY', 'SUCCESS', 325.00, 6.50, NOW());   -- 280 + 30 + 5 + 10 = 325

INSERT INTO delivery_trip (order_id, partner_id, assigned_at, promised_delivery_at,
                           promised_prep_minutes, partner_payout, incentive_amount)
VALUES (@oid,
        (SELECT MIN(partner_id) FROM delivery_partner
         WHERE city_id = (SELECT city_id FROM city WHERE city_name = 'Bengaluru') AND is_active),
        NOW() + INTERVAL 2 MINUTE, NOW() + INTERVAL 40 MINUTE, 20, 50.00, 10.00);

-- ---------------------------------------------------------------------
-- 4. UPDATE single rows: move the order through its life cycle
-- ---------------------------------------------------------------------
UPDATE orders SET order_status = 'ACCEPTED'  WHERE order_id = @oid;
UPDATE orders SET order_status = 'PREPARING' WHERE order_id = @oid;
UPDATE delivery_trip
   SET picked_up_at = assigned_at + INTERVAL 18 MINUTE,
       actual_prep_minutes = 20
 WHERE order_id = @oid;
UPDATE orders SET order_status = 'PICKED_UP' WHERE order_id = @oid;
UPDATE delivery_trip
   SET delivered_at = picked_up_at + INTERVAL 15 MINUTE
 WHERE order_id = @oid;
UPDATE orders SET order_status = 'DELIVERED' WHERE order_id = @oid;

-- The locked formula, computed from the rows we just wrote (Step 4 turns this
-- into fn_order_contribution). Expected: subtotal 280, revenue 95.40, contribution 28.90.
SELECT o.order_id, o.order_status,
       s.subtotal,
       ROUND(s.subtotal * r.commission_pct / 100
             + o.delivery_fee + o.platform_fee + o.packaging_fee, 2)       AS revenue,
       t.partner_payout + t.incentive_amount + t.wait_time_pay             AS delivery_cost,
       p.gateway_fee,
       ROUND(s.subtotal * r.commission_pct / 100
             + o.delivery_fee + o.platform_fee + o.packaging_fee
             - (t.partner_payout + t.incentive_amount + t.wait_time_pay)
             - p.gateway_fee - oc.support_cost, 2)                         AS contribution
FROM orders o
JOIN restaurant r  ON r.restaurant_id = o.restaurant_id
JOIN (SELECT order_id, SUM(quantity * unit_price) AS subtotal
      FROM order_item GROUP BY order_id) s ON s.order_id = o.order_id
JOIN delivery_trip t        ON t.order_id = o.order_id
JOIN payment_transaction p  ON p.order_id = o.order_id AND p.payment_status = 'SUCCESS'
JOIN order_cost oc          ON oc.order_id = o.order_id
WHERE o.order_id = @oid;

-- ---------------------------------------------------------------------
-- 5. Upsert: INSERT ... ON DUPLICATE KEY UPDATE
--    The order already has an order_cost row (PK order_id), so this
--    UPDATEs it instead of failing: a support chat cost Rs 12.
-- ---------------------------------------------------------------------
INSERT INTO order_cost (order_id, support_cost) VALUES (@oid, 12.00) AS new_row
ON DUPLICATE KEY UPDATE support_cost = order_cost.support_cost + new_row.support_cost;
SELECT order_id, support_cost FROM order_cost WHERE order_id = @oid;   -- 12.00

-- ---------------------------------------------------------------------
-- 6. UPDATE with a JOIN: renegotiated contracts, +1 commission point for
--    every restaurant in Mysuru. ROW_COUNT() = rows actually changed.
-- ---------------------------------------------------------------------
SELECT ROUND(AVG(r.commission_pct), 2) AS mysuru_avg_commission_before
FROM restaurant r JOIN city c ON c.city_id = r.city_id WHERE c.city_name = 'Mysuru';

UPDATE restaurant r
JOIN city c ON c.city_id = r.city_id
   SET r.commission_pct = r.commission_pct + 1
 WHERE c.city_name = 'Mysuru' AND r.is_active;
SELECT ROW_COUNT() AS restaurants_updated;

SELECT ROUND(AVG(r.commission_pct), 2) AS mysuru_avg_commission_after
FROM restaurant r JOIN city c ON c.city_id = r.city_id WHERE c.city_name = 'Mysuru';

-- ---------------------------------------------------------------------
-- 7. UPDATE with a derived table and CASE: fix leak L4 by charging refunds back.
--    Restaurant-caused refunds are recovered in full; partner-caused ones
--    up to Rs 100. Only restaurants recovering under 10% are touched.
-- ---------------------------------------------------------------------
SELECT ROUND(SUM(refund_amount - recovered_amount), 2) AS unrecovered_before
FROM refund WHERE refund_status = 'PROCESSED';

-- Why a JOIN to a derived table and not "WHERE ... IN (SELECT ... FROM refund ...)"?
-- MySQL refuses to UPDATE a table that a subquery in the same statement reads
-- (ERROR 1093 "You can't specify target table ... for update in FROM clause").
-- A derived table (subquery in FROM, here "bad") is computed in full first,
-- so the update no longer reads refund while changing it.
UPDATE refund f
JOIN orders o ON o.order_id = f.order_id
JOIN (SELECT o2.restaurant_id
      FROM refund f2 JOIN orders o2 ON o2.order_id = f2.order_id
      WHERE f2.responsibility = 'RESTAURANT' AND f2.refund_status = 'PROCESSED'
      GROUP BY o2.restaurant_id
      HAVING SUM(f2.recovered_amount) < 0.10 * SUM(f2.refund_amount)) AS bad
  ON bad.restaurant_id = o.restaurant_id
   SET f.recovered_amount = CASE f.responsibility
                              WHEN 'RESTAURANT' THEN f.refund_amount
                              WHEN 'PARTNER'    THEN LEAST(f.refund_amount, 100)
                              ELSE f.recovered_amount
                            END
 WHERE f.refund_status = 'PROCESSED';
SELECT ROW_COUNT() AS refunds_charged_back;

SELECT ROUND(SUM(refund_amount - recovered_amount), 2) AS unrecovered_after
FROM refund WHERE refund_status = 'PROCESSED';

-- ---------------------------------------------------------------------
-- 8. UPDATE a JSON column: an analyst tightens the discount rule.
--    JSON_SET changes one key and keeps the rest; updated_at changes
--    by itself (ON UPDATE CURRENT_TIMESTAMP).
-- ---------------------------------------------------------------------
UPDATE leak_rule
   SET threshold_value = 12.00,
       rule_config     = JSON_SET(rule_config, '$.benchmark_pct', 12)
 WHERE rule_name = 'Discount above 15% of subtotal';
SELECT rule_name, threshold_value, rule_config->>'$.benchmark_pct' AS benchmark_pct
FROM leak_rule WHERE rule_name = 'Discount above 15% of subtotal';

-- ---------------------------------------------------------------------
-- 9. Constraints guard UPDATE too
-- ---------------------------------------------------------------------
-- EXPECT ERROR: chk_refund_recovered_le_refund (cannot recover more than was refunded)
UPDATE refund SET recovered_amount = refund_amount + 1 WHERE refund_id = 1;

-- ---------------------------------------------------------------------
-- 10. DELETE and ON DELETE rules, with a SAVEPOINT
-- ---------------------------------------------------------------------
-- EXPECT ERROR: fk_payment_order is ON DELETE RESTRICT. Our demo order has a
-- payment, and money history must never disappear silently.
DELETE FROM orders WHERE order_id = @oid;

-- A second, unpaid order (PLACED, never paid) CAN be deleted ...
INSERT INTO orders (customer_id, restaurant_id, order_time, distance_km)
VALUES (@cust, @rest, NOW(), 2.00);
SET @oid2 = LAST_INSERT_ID();
INSERT INTO order_item (order_id, menu_item_id, quantity, unit_price)
SELECT @oid2, menu_item_id, 1, list_price FROM menu_item WHERE restaurant_id = @rest;
INSERT INTO order_cost (order_id) VALUES (@oid2);
INSERT INTO discount_usage (order_id, coupon_id, discount_amount, used_at)
SELECT @oid2, coupon_id, 20.00, NOW() FROM coupon WHERE coupon_code = 'SAVE20';

SAVEPOINT before_delete;

-- ... and ON DELETE CASCADE takes its order_item, order_cost and
-- discount_usage rows with it.
DELETE FROM orders WHERE order_id = @oid2;
SELECT (SELECT COUNT(*) FROM order_item     WHERE order_id = @oid2) AS items_left,
       (SELECT COUNT(*) FROM order_cost     WHERE order_id = @oid2) AS cost_rows_left,
       (SELECT COUNT(*) FROM discount_usage WHERE order_id = @oid2) AS coupon_rows_left;  -- 0, 0, 0

-- Undo just that delete; the work before the savepoint stays.
ROLLBACK TO SAVEPOINT before_delete;
SELECT COUNT(*) AS order2_is_back FROM orders WHERE order_id = @oid2;                    -- 1

-- Multi-table DELETE with a JOIN: drop the SAVE20 usage on order 2 only.
DELETE du
FROM discount_usage du
JOIN coupon c ON c.coupon_id = du.coupon_id
WHERE du.order_id = @oid2 AND c.coupon_code = 'SAVE20';
SELECT ROW_COUNT() AS coupon_usages_deleted;                                              -- 1

-- DELETE with a correlated subquery: remove dormant accounts (signed up before
-- 2025, never ordered). orders -> customer is RESTRICT, which is why only
-- customers WITHOUT orders may go. Customers they had referred are kept, and
-- ON DELETE SET NULL blanks their referred_by_customer_id (self-FK).
SELECT COUNT(*) AS referees_of_dormant_customers
FROM customer c
JOIN customer ref ON ref.customer_id = c.referred_by_customer_id      -- self-join
WHERE ref.created_at < '2025-01-01'
  AND NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = ref.customer_id);

-- Only customers who joined from 2025 can be referees, so count their blanks.
SET @no_referrer_before = (SELECT COUNT(*) FROM customer
                           WHERE created_at >= '2025-01-01' AND referred_by_customer_id IS NULL);

DELETE FROM customer
 WHERE created_at < '2025-01-01'
   AND NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = customer.customer_id);
SELECT ROW_COUNT() AS dormant_customers_deleted;

SELECT (SELECT COUNT(*) FROM customer
        WHERE created_at >= '2025-01-01' AND referred_by_customer_id IS NULL)
       - @no_referrer_before AS referrers_set_to_null;          -- same number as the referees above

-- ---------------------------------------------------------------------
-- 11. Throw everything away
-- ---------------------------------------------------------------------
ROLLBACK;

SELECT COUNT(*) AS orders_after_demo FROM orders;               -- same as before
SELECT COUNT(*) AS demo_customer_left FROM customer
WHERE email = 'demo.customer@example.com';                      -- 0
