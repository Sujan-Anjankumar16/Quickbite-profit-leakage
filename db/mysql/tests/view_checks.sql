-- =====================================================================
--  QuickBite  -  tests/view_checks.sql   (Step 4)
--  Checks 04_views.sql. Every "breakers" / "mismatch" number must be 0.
--    docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t quickbite' < db/mysql/tests/view_checks.sql
--  Role checks are at the bottom (run as the role's login).
-- =====================================================================
USE quickbite;

-- V1. The view and the function agree on every one of the 60,000 orders.
SELECT 'V1 view vs fn_order_contribution' AS check_name,
       COUNT(*) AS orders_checked,
       SUM(f.contribution <> fn_order_contribution(f.order_id)) AS mismatch
FROM v_order_financials f;

-- V2. One row per order, nothing lost or duplicated by the joins.
SELECT 'V2 view rows vs orders' AS check_name,
       (SELECT COUNT(*) FROM v_order_financials) - (SELECT COUNT(*) FROM orders) AS mismatch;

-- V3. The parts add up: contribution = revenue - every cost (within rounding).
SELECT 'V3 parts add up' AS check_name,
       SUM(ABS(contribution - (revenue - platform_discount - delivery_cost - gateway_fee
                               - support_cost - refund_loss)) > 0.01) AS breakers
FROM v_order_financials;

-- V4. Rule 2: cancelled orders earn nothing and never show a profit.
SELECT 'V4 cancelled with revenue, discount or profit' AS check_name,
       SUM(revenue <> 0 OR platform_discount <> 0 OR contribution > 0) AS breakers,
       COUNT(*) AS cancelled_orders,
       ROUND(AVG(contribution), 2) AS avg_contribution
FROM v_order_financials WHERE order_status = 'CANCELLED';

-- V5. Rule 1: REQUESTED and REJECTED refunds are not in refund_loss.
--     Recompute refund_loss counting ALL statuses. The orders where the
--     answer changes must be exactly the orders that have such refunds.
WITH all_status AS (
  SELECT f.order_id,
         f.refund_loss,
         COALESCE(x.loss, 0) + COALESCE(c.comp, 0) AS loss_all_status,
         f.order_id IN (SELECT order_id FROM refund
                        WHERE refund_status IN ('REQUESTED', 'REJECTED')) AS has_uncounted
  FROM v_order_financials f
  LEFT JOIN (SELECT r.order_id,
                    SUM(IF(o.order_status = 'CANCELLED' AND r.refund_reason = 'CANCELLED', 0,
                           r.refund_amount - r.recovered_amount)) AS loss
             FROM refund r JOIN orders o ON o.order_id = r.order_id
             GROUP BY r.order_id) x ON x.order_id = f.order_id
  LEFT JOIN (SELECT order_id, SUM(compensation_amount) AS comp
             FROM compensation GROUP BY order_id) c ON c.order_id = f.order_id
)
SELECT 'V5 refund status rule' AS check_name,
       SUM(has_uncounted)                                  AS orders_with_uncounted_refunds,
       SUM((refund_loss <> loss_all_status) <> has_uncounted) AS mismatch
FROM all_status;

-- V6. Summary views reconcile with the order view.
SELECT 'V6 monthly totals = order view totals' AS check_name,
       (SELECT SUM(contribution) FROM v_monthly_kpi)
       - (SELECT SUM(contribution) FROM v_order_financials WHERE is_closed) AS mismatch;
SELECT 'V6 city totals = order view totals' AS check_name,
       (SELECT SUM(contribution) FROM v_city_scorecard)
       - (SELECT SUM(contribution) FROM v_order_financials WHERE is_closed) AS mismatch;
SELECT 'V6 restaurant totals = order view totals' AS check_name,
       (SELECT SUM(contribution) FROM v_restaurant_scorecard)
       - (SELECT SUM(contribution) FROM v_order_financials WHERE is_closed) AS mismatch;
SELECT 'V6 coupon uses = discount_usage rows' AS check_name,
       (SELECT SUM(uses) FROM v_coupon_performance) - (SELECT COUNT(*) FROM discount_usage) AS mismatch;

-- V7. Outer joins keep empty rows: Kochi (no restaurants) and Holi-less coupons.
SELECT 'V7 Kochi present with 0 orders' AS check_name,
       COUNT(*) - 1 AS mismatch
FROM v_city_scorecard WHERE city_name = 'Kochi' AND closed_orders = 0;

-- V8. Function edge case: an order that does not exist gives NULL.
SELECT 'V8 missing order gives NULL' AS check_name,
       (fn_order_contribution(999999999) IS NOT NULL) AS mismatch;

-- V9. The team guide's worked example: contribution must be 28.90.
START TRANSACTION;
INSERT INTO restaurant (city_id, restaurant_name, commission_pct) VALUES (1, 'Worked Example Kitchen', 18.00);
SET @r = LAST_INSERT_ID();
INSERT INTO menu_item (restaurant_id, item_name, category, list_price) VALUES (@r, 'Thali', 'Main Course', 140.00);
SET @m = LAST_INSERT_ID();
INSERT INTO orders (customer_id, restaurant_id, order_time, order_status, delivery_fee, platform_fee,
                    packaging_fee, distance_km)
VALUES (1, @r, NOW(), 'DELIVERED', 30, 5, 10, 3);
SET @o = LAST_INSERT_ID();
INSERT INTO order_item VALUES (@o, @m, 2, 140.00);                         -- subtotal 280
INSERT INTO order_cost (order_id) VALUES (@o);
INSERT INTO delivery_trip (order_id, partner_id, assigned_at, picked_up_at, delivered_at,
                           promised_delivery_at, promised_prep_minutes, partner_payout, incentive_amount)
VALUES (@o, 1, NOW(), NOW(), NOW() + INTERVAL 20 MINUTE, NOW() + INTERVAL 30 MINUTE, 15, 50, 10);  -- cost 60
INSERT INTO payment_transaction (order_id, gateway_name, payment_status, transaction_amount, gateway_fee,
                                 transaction_time)
VALUES (@o, 'RAZORPAY', 'SUCCESS', 325, 6.50, NOW());
SELECT 'V9 worked example' AS check_name,
       fn_order_contribution(@o) AS fn_result,
       (SELECT revenue FROM v_order_financials WHERE order_id = @o) AS view_revenue,
       (SELECT contribution FROM v_order_financials WHERE order_id = @o) AS view_result,
       (fn_order_contribution(@o) <> 28.90) AS mismatch;
ROLLBACK;

-- ---------------------------------------------------------------------
-- Role checks (run separately, see README):
--   as qb_viewer_user:  SELECT * FROM v_monthly_kpi;            -> works
--                       SELECT * FROM v_order_financials;       -> SELECT command denied
--   as qb_analyst_user: SELECT fn_order_contribution(1);        -> works
--   as qb_viewer_user:  SELECT fn_order_contribution(1);        -> EXECUTE command denied
-- ---------------------------------------------------------------------
