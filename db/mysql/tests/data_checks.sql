-- =====================================================================
--  QuickBite  -  tests/data_checks.sql
--  Read-only checks on the generated data (Step 3). Changes nothing.
--    docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t quickbite' < db/mysql/tests/data_checks.sql
--
--  Part A: business rules a CHECK constraint cannot express. Each query
--          counts rule breakers, so EVERY number in part A must be 0.
--  Part B: the six planted leaks must stand out in the data.
-- =====================================================================
USE quickbite;

-- ---------------------------------------------------------------------
-- A. Integrity (expected: all zeros)
-- ---------------------------------------------------------------------
SELECT 'A1 orders with no order_cost row' AS rule_check, COUNT(*) AS breakers
FROM orders o LEFT JOIN order_cost oc ON oc.order_id = o.order_id
WHERE oc.order_id IS NULL
UNION ALL
SELECT 'A2 orders with no order_item', COUNT(*)
FROM orders o WHERE NOT EXISTS (SELECT 1 FROM order_item oi WHERE oi.order_id = o.order_id)
UNION ALL
SELECT 'A3 delivered orders without a delivered trip', COUNT(*)
FROM orders o LEFT JOIN delivery_trip t ON t.order_id = o.order_id
WHERE o.order_status = 'DELIVERED' AND t.delivered_at IS NULL
UNION ALL
SELECT 'A4 trips on orders cancelled before accept', COUNT(*)
FROM orders o JOIN delivery_trip t ON t.order_id = o.order_id
WHERE o.cancellation_stage = 'BEFORE_ACCEPT'
UNION ALL
SELECT 'A5 orders placed before the customer signed up', COUNT(*)
FROM orders o JOIN customer c ON c.customer_id = o.customer_id
WHERE o.order_time < c.created_at
UNION ALL
SELECT 'A6 orders placed before the restaurant opened', COUNT(*)
FROM orders o JOIN restaurant r ON r.restaurant_id = o.restaurant_id
WHERE o.order_time < r.created_at
UNION ALL
SELECT 'A7 customers referring themselves', COUNT(*)
FROM customer WHERE referred_by_customer_id = customer_id
UNION ALL
SELECT 'A8 order items from another restaurant''s menu', COUNT(*)
FROM order_item oi
JOIN orders o     ON o.order_id = oi.order_id
JOIN menu_item mi ON mi.menu_item_id = oi.menu_item_id
WHERE mi.restaurant_id <> o.restaurant_id
UNION ALL
SELECT 'A9 trip partner from another city', COUNT(*)
FROM delivery_trip t
JOIN orders o            ON o.order_id = t.order_id
JOIN restaurant r        ON r.restaurant_id = o.restaurant_id
JOIN delivery_partner dp ON dp.partner_id = t.partner_id
WHERE dp.city_id <> r.city_id
UNION ALL
SELECT 'A10 coupons used outside their campaign dates', COUNT(*)
FROM discount_usage du
JOIN coupon c   ON c.coupon_id = du.coupon_id
JOIN campaign k ON k.campaign_id = c.campaign_id
WHERE DATE(du.used_at) NOT BETWEEN k.start_date AND k.end_date
UNION ALL
SELECT 'A11 successful payment amount <> GMV - discount', COUNT(*)
FROM payment_transaction p
JOIN (SELECT o.order_id,
             SUM(oi.quantity * oi.unit_price) + o.delivery_fee + o.platform_fee + o.packaging_fee
               - COALESCE((SELECT SUM(du.discount_amount) FROM discount_usage du
                           WHERE du.order_id = o.order_id), 0) AS should_pay
      FROM orders o JOIN order_item oi ON oi.order_id = o.order_id
      GROUP BY o.order_id) x ON x.order_id = p.order_id
WHERE p.payment_status = 'SUCCESS' AND p.transaction_amount <> x.should_pay;

-- ---------------------------------------------------------------------
-- B. Planted leaks (expected: the leak rows stand out clearly)
-- ---------------------------------------------------------------------

-- B0. The story: orders grow every month while coupon use climbs.
SELECT DATE_FORMAT(o.order_time, '%Y-%m') AS month,
       COUNT(*)                            AS orders,
       ROUND(100 * AVG(EXISTS (SELECT 1 FROM discount_usage du
                               WHERE du.order_id = o.order_id)), 1) AS pct_with_coupon
FROM orders o
GROUP BY month ORDER BY month;

-- B1 (L1 DISCOUNT_OVERSPEND): platform-borne discount by coupon, plus stacking.
SELECT c.coupon_code, c.funded_by,
       COUNT(*)                                                          AS uses,
       ROUND(SUM(du.discount_amount * (1 - c.restaurant_share_pct / 100)), 0) AS platform_discount
FROM discount_usage du JOIN coupon c ON c.coupon_id = du.coupon_id
GROUP BY c.coupon_id, c.coupon_code, c.funded_by
ORDER BY platform_discount DESC;

SELECT 'orders with 2+ coupons' AS stacked, COUNT(*) AS orders
FROM (SELECT order_id FROM discount_usage GROUP BY order_id HAVING COUNT(*) > 1) s;

-- B2 (L2 DELIVERY_COST_OVERRUN): payout vs the rule's benchmark 25 + 7/km.
--     Expect 10 Hyderabad partners near 1.80, everyone else near 1.00.
SELECT dp.partner_id, ci.city_name,
       COUNT(*)                                                     AS trips,
       ROUND(AVG(t.partner_payout / (25 + 7 * o.distance_km)), 2)  AS payout_vs_benchmark
FROM delivery_trip t
JOIN orders o            ON o.order_id = t.order_id
JOIN delivery_partner dp ON dp.partner_id = t.partner_id
JOIN city ci             ON ci.city_id = dp.city_id
WHERE o.order_status = 'DELIVERED'
GROUP BY dp.partner_id, ci.city_name
ORDER BY payout_vs_benchmark DESC
LIMIT 12;

--     and rain incentives: Bengaluru jumps from May 2026.
SELECT ci.city_name, (o.order_time >= '2026-05-01') AS from_may_2026,
       ROUND(AVG(t.incentive_amount), 2) AS avg_rain_incentive
FROM delivery_trip t
JOIN orders o     ON o.order_id = t.order_id
JOIN restaurant r ON r.restaurant_id = o.restaurant_id
JOIN city ci      ON ci.city_id = r.city_id
WHERE o.is_rainy_weather AND o.order_status = 'DELIVERED'
GROUP BY ci.city_name, from_may_2026
ORDER BY avg_rain_incentive DESC
LIMIT 6;

-- B3 (L3 DELAY_COST): six restaurants with prep far over the promise.
--     The prep columns are UNSIGNED: subtracting them directly fails with
--     "BIGINT UNSIGNED value is out of range" whenever the kitchen was EARLY,
--     so BOTH sides are cast to SIGNED first (if either side of "-" is
--     UNSIGNED, MySQL makes the result UNSIGNED too).
SELECT r.restaurant_id, r.restaurant_name,
       ROUND(AVG(CAST(t.actual_prep_minutes AS SIGNED)
                 - CAST(t.promised_prep_minutes AS SIGNED)), 1)              AS avg_prep_overrun_min,
       ROUND(AVG(TIMESTAMPDIFF(MINUTE, t.promised_delivery_at, t.delivered_at)), 1) AS avg_delay_min,
       ROUND(SUM(t.wait_time_pay), 0)                                          AS wait_time_pay
FROM delivery_trip t
JOIN orders o     ON o.order_id = t.order_id
JOIN restaurant r ON r.restaurant_id = o.restaurant_id
WHERE t.delivered_at IS NOT NULL
GROUP BY r.restaurant_id, r.restaurant_name
ORDER BY avg_prep_overrun_min DESC
LIMIT 8;

-- B4 (L4 UNRECOVERED_REFUND): restaurant-caused refunds that were never recovered.
SELECT r.restaurant_id, r.restaurant_name,
       COUNT(*)                                        AS restaurant_refunds,
       ROUND(SUM(f.refund_amount), 0)                  AS refunded,
       ROUND(100 * SUM(f.recovered_amount) / SUM(f.refund_amount), 1) AS pct_recovered
FROM refund f
JOIN orders o     ON o.order_id = f.order_id
JOIN restaurant r ON r.restaurant_id = o.restaurant_id
WHERE f.responsibility = 'RESTAURANT' AND f.refund_status = 'PROCESSED'
GROUP BY r.restaurant_id, r.restaurant_name
ORDER BY refunded - SUM(f.recovered_amount) DESC
LIMIT 8;

-- B5 (L5 GATEWAY_FEE_EXCESS): effective fee rate by gateway, before/after May 2026.
SELECT gateway_name, (transaction_time >= '2026-05-01') AS from_may_2026,
       COUNT(*)                                                    AS payments,
       ROUND(100 * SUM(gateway_fee) / SUM(transaction_amount), 2) AS fee_pct
FROM payment_transaction
WHERE payment_status = 'SUCCESS'
GROUP BY gateway_name, from_may_2026
ORDER BY gateway_name, from_may_2026;

-- B6 (L6 LOW_VALUE_ORDER): share of tiny baskets per month and how many used FREEDEL.
SELECT DATE_FORMAT(o.order_time, '%Y-%m') AS month,
       ROUND(100 * AVG(s.subtotal < 149), 1) AS pct_below_149,
       SUM(s.subtotal < 149 AND EXISTS (SELECT 1 FROM discount_usage du
                                        JOIN coupon c ON c.coupon_id = du.coupon_id
                                        WHERE du.order_id = o.order_id
                                          AND c.coupon_code = 'FREEDEL')) AS tiny_with_freedel
FROM orders o
JOIN (SELECT order_id, SUM(quantity * unit_price) AS subtotal
      FROM order_item GROUP BY order_id) s ON s.order_id = o.order_id
GROUP BY month ORDER BY month;
