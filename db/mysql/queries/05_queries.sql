-- =====================================================================
--  QuickBite  -  queries/05_queries.sql
--  Join, nested, correlated and recursive queries
--  (rubric item 3: "nested / correlated / recursive / join queries", 4 marks)
--
--  Every query answers a business question; most of them surface one of
--  the planted leaks (L1-L6). Read-only. Needs 04_views.sql and the data.
--    docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t quickbite' < db/mysql/queries/05_queries.sql
--
--  Index
--    J1  multi-table INNER JOIN incl. region self-join   worst restaurants, last 3 months
--    J2  LEFT JOIN anti-joins                             empty cities, campaigns, zones
--    J3  self-join on customer                            top referrers
--    J4  RIGHT JOIN                                       leak types and their rules
--    J5  JOIN on JSON rule settings + LATERAL derived     delivery cost overrun (L2)
--    J6  JOIN + benchmark from leak_rule                  gateway fee excess (L5)
--    N1  subquery in HAVING over a derived table          refunds never recovered (L4)
--    N2  IN ... AND IN ...                                stacked Feast coupons (L1)
--    N3  scalar subquery in SELECT                        each coupon's share of discount cost (L1)
--    N4  > ALL (subquery)                                 slow kitchens (L3)
--    N5  NOT IN                                           sign-ups who never ordered
--    N6  derived table + CASE                             tiny baskets (L6)
--    C1  correlated subquery in WHERE                     refund rate vs own city
--    C2  correlated NOT EXISTS                            loyal customers who never make money
--    C3  correlated subquery in SELECT (ORDER BY LIMIT 1) best-selling item per city
--    R1  WITH RECURSIVE region tree + roll-up             contribution at every level
--    R2  WITH RECURSIVE referral chains                   chain depth and network size
--    R3  WITH RECURSIVE month calendar + window functions running total, month-on-month
--    P1  CTE chain + running SUM() OVER                   Pareto: leak types making up 80% of leak loss
--    P2  CTE chain + running SUM() OVER                   Pareto: restaurants making up 80% (summary + top 15)
-- =====================================================================
USE quickbite;

-- =====================================================================
--  JOINS
-- =====================================================================

-- J1. Which 10 restaurants lost the most money in Aug-Oct 2026, and where are they?
--     Five tables; region is joined twice (state, then its parent zone).
SELECT r.restaurant_id, r.restaurant_name, ci.city_name,
       st.region_name                 AS state,
       zn.region_name                 AS zone,
       COUNT(*)                       AS closed_orders,
       SUM(f.contribution < 0)        AS loss_making_orders,
       SUM(f.contribution)            AS contribution
FROM v_order_financials f
JOIN restaurant r  ON r.restaurant_id = f.restaurant_id
JOIN city ci       ON ci.city_id      = r.city_id
JOIN region st     ON st.region_id    = ci.region_id
JOIN region zn     ON zn.region_id    = st.parent_region_id
WHERE f.is_closed AND f.order_time >= '2026-08-01'
GROUP BY r.restaurant_id, r.restaurant_name, ci.city_name, st.region_name, zn.region_name
ORDER BY contribution ASC
LIMIT 10;

-- J2. Anti-joins (LEFT JOIN ... WHERE right side IS NULL): things with nothing attached.
SELECT 'city without restaurants' AS what, ci.city_name AS name
FROM city ci LEFT JOIN restaurant r ON r.city_id = ci.city_id
WHERE r.restaurant_id IS NULL
UNION ALL
SELECT 'campaign without coupons', k.campaign_name
FROM campaign k LEFT JOIN coupon c ON c.campaign_id = k.campaign_id
WHERE c.coupon_id IS NULL
UNION ALL
SELECT 'zone without states', z.region_name
FROM region z LEFT JOIN region s ON s.parent_region_id = z.region_id
WHERE z.region_type = 'ZONE' AND s.region_id IS NULL;

-- J3. Self-join: who brought in the most customers, and how much did those
--     referees order? (customer c = referee, customer ref = referrer)
SELECT ref.customer_id               AS referrer_id,
       ref.full_name                 AS referrer,
       COUNT(DISTINCT c.customer_id) AS referees,
       COUNT(o.order_id)             AS referee_orders
FROM customer c
JOIN customer ref     ON ref.customer_id = c.referred_by_customer_id
LEFT JOIN orders o    ON o.customer_id   = c.customer_id
GROUP BY ref.customer_id, ref.full_name
ORDER BY referees DESC, referee_orders DESC
LIMIT 10;

-- J4. RIGHT JOIN: every leak type, even one with no active rule, with its rules.
SELECT lt.leak_type_id, lt.leak_name,
       COUNT(lr.leak_rule_id)                                    AS active_rules,
       GROUP_CONCAT(lr.rule_name ORDER BY lr.leak_rule_id SEPARATOR ' | ') AS rules
FROM leak_rule lr
RIGHT JOIN leak_type lt ON lt.leak_type_id = lr.leak_type_id AND lr.is_active
GROUP BY lt.leak_type_id, lt.leak_name
ORDER BY lt.leak_type_id;

-- J5. L2: delivery cost above the benchmark, by partner. The benchmark is read
--     from leak_rule.rule_config (JSON), so tuning the rule changes the answer.
--     Rule 3 applies in normal conditions, rule 4 in peak or rain.
--     ->> returns text, so each setting is CAST to DECIMAL (exact arithmetic).
SELECT dp.partner_id, dp.partner_name, ci.city_name,
       COUNT(*)                                     AS trips_over_benchmark,
       SUM(t.partner_payout + t.incentive_amount - b.allowed) AS excess_cost
FROM delivery_trip t
JOIN orders o            ON o.order_id    = t.order_id
JOIN delivery_partner dp ON dp.partner_id = t.partner_id
JOIN city ci             ON ci.city_id    = dp.city_id
JOIN leak_rule lr        ON lr.leak_rule_id = IF(o.is_peak_period OR o.is_rainy_weather, 4, 3)
JOIN LATERAL (
  SELECT ROUND((CAST(lr.rule_config->>'$.base_pay' AS DECIMAL(10,2))
                + CAST(lr.rule_config->>'$.per_km' AS DECIMAL(10,2)) * o.distance_km)
               * (1 + CAST(lr.rule_config->>'$.tolerance_pct' AS DECIMAL(10,2)) / 100), 2) AS allowed
) AS b
WHERE o.order_status = 'DELIVERED'
  AND t.partner_payout + t.incentive_amount > b.allowed
GROUP BY dp.partner_id, dp.partner_name, ci.city_name
ORDER BY excess_cost DESC
LIMIT 12;

-- J6. L5: gateway fee above rule 7's benchmark (2%), by gateway, before and after 1 May 2026.
SELECT p.gateway_name,
       IF(p.transaction_time >= '2026-05-01', 'May-Oct 2026', 'Nov 2025-Apr 2026') AS period,
       COUNT(*)                                                         AS payments,
       ROUND(100 * SUM(p.gateway_fee) / SUM(p.transaction_amount), 2)  AS fee_pct,
       ROUND(SUM(GREATEST(p.gateway_fee - p.transaction_amount * lr.threshold_value / 100, 0)), 2) AS excess_fee
FROM payment_transaction p
JOIN leak_rule lr ON lr.rule_name = 'Gateway fee above 2%'
WHERE p.payment_status = 'SUCCESS' AND p.gateway_name <> 'COD'
GROUP BY p.gateway_name, period
ORDER BY excess_fee DESC;

-- =====================================================================
--  NESTED (non-correlated) SUBQUERIES
-- =====================================================================

-- N1. L4: restaurants whose unrecovered refunds are over 3x the average
--     restaurant's. The inner query runs once; HAVING compares each group to it.
SELECT r.restaurant_id, r.restaurant_name,
       COUNT(*)                                           AS refunds,
       ROUND(SUM(f.refund_amount - f.recovered_amount), 2) AS unrecovered
FROM refund f
JOIN orders o     ON o.order_id      = f.order_id
JOIN restaurant r ON r.restaurant_id = o.restaurant_id
WHERE f.refund_status IN ('APPROVED', 'PROCESSED')
GROUP BY r.restaurant_id, r.restaurant_name
HAVING SUM(f.refund_amount - f.recovered_amount) > 3 * (
  SELECT AVG(per_restaurant.loss)
  FROM (SELECT SUM(f2.refund_amount - f2.recovered_amount) AS loss
        FROM refund f2 JOIN orders o2 ON o2.order_id = f2.order_id
        WHERE f2.refund_status IN ('APPROVED', 'PROCESSED')
        GROUP BY o2.restaurant_id) AS per_restaurant)
ORDER BY unrecovered DESC;

-- N2. L1: orders that stacked FEAST60 and FEASTFREE, and what that cost the platform.
SELECT COUNT(*)                                   AS stacked_orders,
       SUM(platform_discount)                     AS platform_discount,
       ROUND(AVG(contribution), 2)                AS avg_contribution,
       ROUND(100 * AVG(contribution < 0), 1)      AS loss_making_pct
FROM v_order_financials
WHERE order_id IN (SELECT du.order_id FROM discount_usage du
                   JOIN coupon c ON c.coupon_id = du.coupon_id WHERE c.coupon_code = 'FEAST60')
  AND order_id IN (SELECT du.order_id FROM discount_usage du
                   JOIN coupon c ON c.coupon_id = du.coupon_id WHERE c.coupon_code = 'FEASTFREE');

-- N3. L1: each coupon's share of the platform's total discount bill
--     (scalar subquery in SELECT, evaluated once).
SELECT coupon_code, campaign_name, funded_by, uses, platform_cost,
       ROUND(100 * platform_cost / (SELECT SUM(platform_cost) FROM v_coupon_performance), 1) AS pct_of_discount_bill,
       avg_order_contribution, loss_making_pct
FROM v_coupon_performance
ORDER BY platform_cost DESC;

-- N4. L3: restaurants whose average prep overrun is worse than EVERY city's average.
--     (UNSIGNED columns are cast to SIGNED: early kitchens give negative overruns.)
SELECT r.restaurant_id, r.restaurant_name, ci.city_name,
       ROUND(AVG(CAST(t.actual_prep_minutes AS SIGNED) - CAST(t.promised_prep_minutes AS SIGNED)), 1) AS avg_prep_overrun,
       ROUND(SUM(t.wait_time_pay), 2) AS wait_time_pay
FROM delivery_trip t
JOIN orders o     ON o.order_id      = t.order_id
JOIN restaurant r ON r.restaurant_id = o.restaurant_id
JOIN city ci      ON ci.city_id      = r.city_id
WHERE t.actual_prep_minutes IS NOT NULL
GROUP BY r.restaurant_id, r.restaurant_name, ci.city_name
HAVING AVG(CAST(t.actual_prep_minutes AS SIGNED) - CAST(t.promised_prep_minutes AS SIGNED)) > ALL (
  SELECT AVG(CAST(t2.actual_prep_minutes AS SIGNED) - CAST(t2.promised_prep_minutes AS SIGNED))
  FROM delivery_trip t2
  JOIN orders o2     ON o2.order_id      = t2.order_id
  JOIN restaurant r2 ON r2.restaurant_id = o2.restaurant_id
  WHERE t2.actual_prep_minutes IS NOT NULL
  GROUP BY r2.city_id)
ORDER BY avg_prep_overrun DESC;

-- N5. Sign-ups who never placed an order, by sign-up quarter (NOT IN).
--     Safe here because orders.customer_id is NOT NULL (NOT IN with a NULL
--     in the list would return no rows at all).
SELECT CONCAT(YEAR(created_at), '-Q', QUARTER(created_at)) AS signup_quarter,
       COUNT(*)                                             AS never_ordered
FROM customer
WHERE customer_id NOT IN (SELECT customer_id FROM orders)
GROUP BY signup_quarter
ORDER BY signup_quarter;

-- N6. L6: tiny baskets (rule 8: subtotal below 149) per month vs the rest.
SELECT x.order_month,
       SUM(x.segment = 'tiny')                                        AS tiny_orders,
       ROUND(100 * AVG(x.segment = 'tiny'), 1)                        AS tiny_pct,
       ROUND(AVG(IF(x.segment = 'tiny', x.contribution, NULL)), 2)    AS tiny_avg_contribution,
       ROUND(AVG(IF(x.segment = 'normal', x.contribution, NULL)), 2)  AS normal_avg_contribution
FROM (SELECT f.order_month, f.contribution,
             CASE WHEN f.food_subtotal < (SELECT threshold_value FROM leak_rule
                                          WHERE rule_name = 'Basket below 149')
                  THEN 'tiny' ELSE 'normal' END AS segment
      FROM v_order_financials f
      WHERE f.order_status = 'DELIVERED') AS x
GROUP BY x.order_month
ORDER BY x.order_month;

-- =====================================================================
--  CORRELATED SUBQUERIES (the inner query uses a column of the outer row)
-- =====================================================================

-- C1. Restaurants whose refund rate is more than double their OWN city's rate.
--     The subquery is re-evaluated for each restaurant row (x.city_id).
SELECT x.restaurant_id, x.restaurant_name, x.city_name, x.delivered,
       ROUND(100 * x.refunds / x.delivered, 1) AS refund_rate_pct
FROM (SELECT r.restaurant_id, r.restaurant_name, r.city_id, ci.city_name,
             COUNT(DISTINCT o.order_id) AS delivered,
             COUNT(f.refund_id)         AS refunds
      FROM restaurant r
      JOIN city ci        ON ci.city_id = r.city_id
      JOIN orders o       ON o.restaurant_id = r.restaurant_id AND o.order_status = 'DELIVERED'
      LEFT JOIN refund f  ON f.order_id = o.order_id
      GROUP BY r.restaurant_id, r.restaurant_name, r.city_id, ci.city_name) AS x
WHERE x.delivered >= 50
  AND x.refunds / x.delivered > 2 * (
      SELECT COUNT(f2.refund_id) / COUNT(DISTINCT o2.order_id)
      FROM orders o2
      JOIN restaurant r2  ON r2.restaurant_id = o2.restaurant_id
      LEFT JOIN refund f2 ON f2.order_id = o2.order_id
      WHERE r2.city_id = x.city_id                    -- correlation
        AND o2.order_status = 'DELIVERED')
ORDER BY refund_rate_pct DESC;

-- C2. Loyal customers (5+ closed orders) who have NEVER produced a profitable order.
SELECT c.customer_id, c.full_name,
       COUNT(*)              AS closed_orders,
       SUM(f.contribution)   AS total_contribution
FROM customer c
JOIN v_order_financials f ON f.customer_id = c.customer_id AND f.is_closed
WHERE NOT EXISTS (SELECT 1 FROM v_order_financials g
                  WHERE g.customer_id = c.customer_id        -- correlation
                    AND g.is_closed AND g.contribution > 0)
GROUP BY c.customer_id, c.full_name
HAVING COUNT(*) >= 5
ORDER BY total_contribution ASC
LIMIT 10;

-- C3. Best-selling menu item (by sales value) in each active city (correlated subquery in SELECT).
SELECT ci.city_name,
       (SELECT mi.item_name
        FROM order_item oi
        JOIN menu_item mi  ON mi.menu_item_id  = oi.menu_item_id
        JOIN restaurant r  ON r.restaurant_id  = mi.restaurant_id
        WHERE r.city_id = ci.city_id                         -- correlation
        GROUP BY mi.item_name
        ORDER BY SUM(oi.quantity * oi.unit_price) DESC
        LIMIT 1) AS best_seller
FROM city ci
WHERE ci.is_active
ORDER BY ci.city_id;

-- =====================================================================
--  RECURSIVE QUERIES (WITH RECURSIVE)
-- =====================================================================

-- R1. Region tree (PART_OF) with contribution rolled up to EVERY level.
--     tree: walks down from India, building depth and path.
--     reach: every (ancestor, descendant) pair, including (x, x), so a
--     state's cities also count for its zone and for India.
WITH RECURSIVE
tree AS (
  SELECT region_id, region_name, region_type, 0 AS depth,
         CAST(region_name AS CHAR(200)) AS path
  FROM region WHERE parent_region_id IS NULL
  UNION ALL
  SELECT ch.region_id, ch.region_name, ch.region_type, t.depth + 1,
         CONCAT(t.path, ' > ', ch.region_name)
  FROM region ch JOIN tree t ON ch.parent_region_id = t.region_id
),
reach AS (
  SELECT region_id AS ancestor_id, region_id AS descendant_id FROM region
  UNION ALL
  SELECT r.ancestor_id, ch.region_id
  FROM reach r JOIN region ch ON ch.parent_region_id = r.descendant_id
)
SELECT CONCAT(REPEAT('    ', t.depth), t.region_name) AS region,
       t.region_type,
       COUNT(cs.city_id)                               AS cities,
       COALESCE(SUM(cs.closed_orders), 0)              AS closed_orders,
       COALESCE(SUM(cs.contribution), 0)               AS contribution,
       ROUND(SUM(cs.contribution) / NULLIF(SUM(cs.delivered_orders), 0), 2) AS contribution_per_delivered
FROM tree t
LEFT JOIN reach rc           ON rc.ancestor_id = t.region_id
LEFT JOIN v_city_scorecard cs ON cs.city_id IN (SELECT city_id FROM city WHERE region_id = rc.descendant_id)
GROUP BY t.region_id, t.region_name, t.region_type, t.depth, t.path
ORDER BY t.path;

-- R2. Referral chains (REFERS): for every customer, who started the chain and how deep it is.
--     The anchor is everyone with no referrer; each step adds their referees.
WITH RECURSIVE chain AS (
  SELECT customer_id, customer_id AS root_id, 0 AS depth
  FROM customer WHERE referred_by_customer_id IS NULL
  UNION ALL
  SELECT c.customer_id, ch.root_id, ch.depth + 1
  FROM customer c JOIN chain ch ON c.referred_by_customer_id = ch.customer_id
  WHERE ch.depth < 50                                   -- guard against a cycle
)
SELECT depth, COUNT(*) AS customers
FROM chain GROUP BY depth ORDER BY depth;

WITH RECURSIVE chain AS (
  SELECT customer_id, customer_id AS root_id, 0 AS depth
  FROM customer WHERE referred_by_customer_id IS NULL
  UNION ALL
  SELECT c.customer_id, ch.root_id, ch.depth + 1
  FROM customer c JOIN chain ch ON c.referred_by_customer_id = ch.customer_id
  WHERE ch.depth < 50
)
SELECT ch.root_id, c.full_name AS chain_starter,
       COUNT(*) - 1   AS network_size,
       MAX(ch.depth)  AS deepest_level
FROM chain ch JOIN customer c ON c.customer_id = ch.root_id
GROUP BY ch.root_id, c.full_name
ORDER BY network_size DESC, deepest_level DESC
LIMIT 5;

-- R3. A recursive month calendar (so a month with no orders would still show
--     as 0), joined to the KPIs, with a running total and month-on-month change.
WITH RECURSIVE months AS (
  SELECT DATE('2025-11-01') AS month_start
  UNION ALL
  SELECT month_start + INTERVAL 1 MONTH FROM months WHERE month_start < '2026-10-01'
)
SELECT DATE_FORMAT(m.month_start, '%Y-%m')                         AS month,
       COALESCE(k.revenue, 0)                                      AS revenue,
       COALESCE(k.contribution, 0)                                 AS contribution,
       SUM(COALESCE(k.contribution, 0)) OVER (ORDER BY m.month_start) AS running_contribution,
       COALESCE(k.contribution, 0)
         - LAG(COALESCE(k.contribution, 0)) OVER (ORDER BY m.month_start) AS change_vs_last_month
FROM months m
LEFT JOIN v_monthly_kpi k ON k.order_month = DATE_FORMAT(m.month_start, '%Y-%m')
ORDER BY m.month_start;

-- =====================================================================
--  PARETO (non-recursive CTE chains + window functions)
--  "Which few causes make up 80% of the leak loss?"
--  Uses PRIMARY leaks of the LATEST detection run, so every order is counted
--  once (LOW_VALUE_ORDER is the order's whole loss and would otherwise
--  double-count with the other types). The cut-off keeps every row whose
--  cumulative share BEFORE it was still below 80%, i.e. the row that crosses
--  80% is included.
-- =====================================================================

-- P1. Pareto by leak type
WITH
latest_run AS (
  SELECT detection_run_id FROM leakage_record
  ORDER BY detected_at DESC, leakage_record_id DESC LIMIT 1
),
by_type AS (
  SELECT lt.leak_name, COUNT(*) AS orders, SUM(lr.leak_amount) AS leak
  FROM leakage_record lr
  JOIN latest_run run ON run.detection_run_id = lr.detection_run_id
  JOIN leak_type lt   ON lt.leak_type_id = lr.leak_type_id
  WHERE lr.is_primary
  GROUP BY lt.leak_name
),
pareto AS (
  SELECT leak_name, orders, leak,
         ROUND(100 * leak / SUM(leak) OVER (), 1)                                   AS pct,
         ROUND(100 * SUM(leak) OVER (ORDER BY leak DESC) / SUM(leak) OVER (), 1)    AS cum_pct,
         100 * (SUM(leak) OVER (ORDER BY leak DESC) - leak) / SUM(leak) OVER ()     AS cum_before
  FROM by_type
)
SELECT leak_name, orders, leak, pct, cum_pct,
       IF(cum_before < 80, 'yes', '') AS in_top_80
FROM pareto
ORDER BY leak DESC;

-- P2. Pareto by restaurant: how many restaurants make up 80% of the loss?
WITH
latest_run AS (
  SELECT detection_run_id FROM leakage_record
  ORDER BY detected_at DESC, leakage_record_id DESC LIMIT 1
),
by_restaurant AS (
  SELECT o.restaurant_id, SUM(lr.leak_amount) AS leak
  FROM leakage_record lr
  JOIN latest_run run ON run.detection_run_id = lr.detection_run_id
  JOIN orders o       ON o.order_id = lr.order_id
  WHERE lr.is_primary
  GROUP BY o.restaurant_id
),
pareto AS (
  SELECT restaurant_id, leak,
         ROW_NUMBER() OVER (ORDER BY leak DESC, restaurant_id)                                AS rank_no,
         100 * SUM(leak) OVER (ORDER BY leak DESC, restaurant_id) / SUM(leak) OVER ()         AS cum_pct,
         100 * (SUM(leak) OVER (ORDER BY leak DESC, restaurant_id) - leak) / SUM(leak) OVER () AS cum_before
  FROM by_restaurant
)
SELECT COUNT(*)                                                      AS restaurants_with_leaks,
       SUM(cum_before < 80)                                          AS restaurants_for_80_pct,
       ROUND(100 * SUM(cum_before < 80) / COUNT(*), 1)               AS pct_of_restaurants,
       ROUND(SUM(IF(cum_before < 80, leak, 0)), 2)                   AS their_leak,
       ROUND(SUM(leak), 2)                                           AS total_leak,
       (SELECT ROUND(100 * SUM(leak) / (SELECT SUM(leak) FROM pareto), 1)
        FROM pareto WHERE rank_no <= 0.2 * (SELECT COUNT(*) FROM pareto)) AS top_20pct_share_of_leak
FROM pareto;

WITH
latest_run AS (
  SELECT detection_run_id FROM leakage_record
  ORDER BY detected_at DESC, leakage_record_id DESC LIMIT 1
),
by_restaurant AS (
  SELECT o.restaurant_id, SUM(lr.leak_amount) AS leak,
         SUM(lr.leak_type_id = 1) AS discount_orders, COUNT(*) AS leak_orders
  FROM leakage_record lr
  JOIN latest_run run ON run.detection_run_id = lr.detection_run_id
  JOIN orders o       ON o.order_id = lr.order_id
  WHERE lr.is_primary
  GROUP BY o.restaurant_id
),
pareto AS (
  SELECT restaurant_id, leak, leak_orders, discount_orders,
         ROW_NUMBER() OVER (ORDER BY leak DESC, restaurant_id)                         AS rank_no,
         ROUND(100 * SUM(leak) OVER (ORDER BY leak DESC, restaurant_id) / SUM(leak) OVER (), 1) AS cum_pct
  FROM by_restaurant
)
SELECT p.rank_no, p.restaurant_id, r.restaurant_name, ci.city_name,
       p.leak_orders, p.leak, p.cum_pct,
       (SELECT lt.leak_name
        FROM leakage_record lr2
        JOIN latest_run run2 ON run2.detection_run_id = lr2.detection_run_id
        JOIN orders o2       ON o2.order_id = lr2.order_id
        JOIN leak_type lt    ON lt.leak_type_id = lr2.leak_type_id
        WHERE lr2.is_primary AND o2.restaurant_id = p.restaurant_id
        GROUP BY lt.leak_name ORDER BY SUM(lr2.leak_amount) DESC LIMIT 1) AS main_leak
FROM pareto p
JOIN restaurant r ON r.restaurant_id = p.restaurant_id
JOIN city ci      ON ci.city_id = r.city_id
WHERE p.rank_no <= 15
ORDER BY p.rank_no;
