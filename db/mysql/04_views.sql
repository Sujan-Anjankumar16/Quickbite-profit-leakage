-- =====================================================================
--  QuickBite  -  04_views.sql
--  Views and fn_order_contribution (derived attributes of the ER diagram:
--  food_subtotal, GMV, delay_minutes, platform_discount_amount,
--  refund_loss_amount, contribution_amount)
--
--  Locked formulas, plus two rules decided in Step 4:
--    Food subtotal  = SUM(quantity * unit_price)
--    GMV            = food subtotal + delivery_fee + platform_fee + packaging_fee
--    Revenue        = food subtotal * commission_pct/100 + the three fees
--    Platform disc. = SUM(discount_amount * (1 - restaurant_share_pct/100))
--    Delivery cost  = partner_payout + incentive_amount + wait_time_pay
--    Refund loss    = SUM(refund_amount) - SUM(recovered_amount) + SUM(compensation_amount)
--    Contribution   = revenue - platform disc. - delivery cost - gateway fee
--                     - support cost - refund loss
--    Rule 1: refunds count only when refund_status is APPROVED or PROCESSED.
--    Rule 2: a CANCELLED order sold nothing, so revenue = 0, platform discount = 0
--            and its CANCELLED-reason refunds (money handed back) are ignored.
--            It still loses what it really cost: delivery, gateway fee,
--            support and compensation.
--    Open orders (PLACED .. PICKED_UP) use the formula as it stands today;
--    the summary views count only closed orders (DELIVERED, CANCELLED).
--
--  The view computes in bulk (one GROUP BY per child table); the function
--  computes one order with indexed lookups. tests/view_checks.sql proves
--  both give the same answer for every order.
--
--  Re-runnable. Apply by hand:
--    docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" quickbite' < db/mysql/04_views.sql
-- =====================================================================
USE quickbite;

-- ---------------------------------------------------------------------
-- 1. v_order_financials: one row per order, every derived amount
-- ---------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_order_financials AS
SELECT
  b.order_id, b.order_time, b.order_month, b.order_status, b.cancellation_stage,
  b.is_closed, b.customer_id, b.restaurant_id, b.city_id,
  b.is_peak_period, b.is_rainy_weather, b.distance_km,
  b.food_subtotal, b.gmv, b.revenue, b.discount_amount, b.coupon_count,
  b.platform_discount, b.delivery_cost, b.gateway_fee, b.support_cost,
  b.refund_loss, b.delay_minutes,
  ROUND(b.revenue_exact - b.platform_discount_exact - b.delivery_cost - b.gateway_fee
        - b.support_cost - b.refund_loss, 2)                         AS contribution
FROM (
  SELECT
    o.order_id,
    o.order_time,
    DATE_FORMAT(o.order_time, '%Y-%m')                               AS order_month,
    o.order_status,
    o.cancellation_stage,
    (o.order_status IN ('DELIVERED', 'CANCELLED'))                   AS is_closed,
    o.customer_id,
    o.restaurant_id,
    r.city_id,
    o.is_peak_period,
    o.is_rainy_weather,
    o.distance_km,
    s.food_subtotal,
    s.food_subtotal + o.delivery_fee + o.platform_fee + o.packaging_fee AS gmv,
    -- exact values feed the contribution; rounded copies are for display
    IF(o.order_status = 'CANCELLED', 0,
       s.food_subtotal * r.commission_pct / 100
       + o.delivery_fee + o.platform_fee + o.packaging_fee)          AS revenue_exact,
    ROUND(IF(o.order_status = 'CANCELLED', 0,
       s.food_subtotal * r.commission_pct / 100
       + o.delivery_fee + o.platform_fee + o.packaging_fee), 2)      AS revenue,
    COALESCE(d.discount_amount, 0)                                   AS discount_amount,
    COALESCE(d.coupon_count, 0)                                      AS coupon_count,
    IF(o.order_status = 'CANCELLED', 0, COALESCE(d.platform_discount, 0)) AS platform_discount_exact,
    ROUND(IF(o.order_status = 'CANCELLED', 0, COALESCE(d.platform_discount, 0)), 2) AS platform_discount,
    COALESCE(t.partner_payout + t.incentive_amount + t.wait_time_pay, 0) AS delivery_cost,
    COALESCE(p.gateway_fee, 0)                                       AS gateway_fee,
    COALESCE(oc.support_cost, 0)                                     AS support_cost,
    COALESCE(IF(o.order_status = 'CANCELLED', f.non_cancel_loss, f.all_loss), 0)
      + COALESCE(c.compensation, 0)                                  AS refund_loss,
    ROUND(TIMESTAMPDIFF(SECOND, t.promised_delivery_at, t.delivered_at) / 60, 1) AS delay_minutes
  FROM orders o
  JOIN restaurant r ON r.restaurant_id = o.restaurant_id
  JOIN (SELECT order_id, SUM(quantity * unit_price) AS food_subtotal
        FROM order_item GROUP BY order_id) s ON s.order_id = o.order_id
  LEFT JOIN (SELECT du.order_id,
                    SUM(du.discount_amount)                                     AS discount_amount,
                    COUNT(*)                                                    AS coupon_count,
                    SUM(du.discount_amount * (1 - cp.restaurant_share_pct / 100)) AS platform_discount
             FROM discount_usage du JOIN coupon cp ON cp.coupon_id = du.coupon_id
             GROUP BY du.order_id) d ON d.order_id = o.order_id
  LEFT JOIN delivery_trip t ON t.order_id = o.order_id
  LEFT JOIN (SELECT order_id, SUM(gateway_fee) AS gateway_fee
             FROM payment_transaction GROUP BY order_id) p ON p.order_id = o.order_id
  LEFT JOIN order_cost oc ON oc.order_id = o.order_id
  LEFT JOIN (SELECT order_id,
                    SUM(refund_amount - recovered_amount)                        AS all_loss,
                    SUM(IF(refund_reason = 'CANCELLED', 0, refund_amount - recovered_amount)) AS non_cancel_loss
             FROM refund
             WHERE refund_status IN ('APPROVED', 'PROCESSED')
             GROUP BY order_id) f ON f.order_id = o.order_id
  LEFT JOIN (SELECT order_id, SUM(compensation_amount) AS compensation
             FROM compensation GROUP BY order_id) c ON c.order_id = o.order_id
) AS b;

-- ---------------------------------------------------------------------
-- 2. v_monthly_kpi: the headline trend (closed orders only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_monthly_kpi AS
SELECT
  order_month,
  COUNT(*)                                                    AS closed_orders,
  SUM(order_status = 'DELIVERED')                             AS delivered_orders,
  ROUND(100 * AVG(order_status = 'CANCELLED'), 2)             AS cancel_rate_pct,
  SUM(IF(order_status = 'DELIVERED', gmv, 0))                 AS gmv,
  SUM(revenue)                                                AS revenue,
  SUM(platform_discount)                                      AS platform_discount,
  SUM(delivery_cost)                                          AS delivery_cost,
  SUM(gateway_fee)                                            AS gateway_fee,
  SUM(support_cost)                                           AS support_cost,
  SUM(refund_loss)                                            AS refund_loss,
  SUM(contribution)                                           AS contribution,
  ROUND(SUM(contribution) / NULLIF(SUM(order_status = 'DELIVERED'), 0), 2) AS contribution_per_delivered,
  SUM(contribution < 0)                                       AS loss_making_orders,
  -SUM(LEAST(contribution, 0))                                AS total_loss
FROM v_order_financials
WHERE is_closed
GROUP BY order_month;

-- ---------------------------------------------------------------------
-- 3. v_city_scorecard: city with its state and zone (region tree)
-- ---------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_city_scorecard AS
SELECT
  ci.city_id, ci.city_name,
  st.region_name                                              AS state_name,
  zn.region_name                                              AS zone_name,
  COUNT(f.order_id)                                           AS closed_orders,
  COALESCE(SUM(f.order_status = 'DELIVERED'), 0)              AS delivered_orders,
  COALESCE(SUM(f.revenue), 0)                                 AS revenue,
  COALESCE(SUM(f.contribution), 0)                            AS contribution,
  ROUND(SUM(f.contribution) / NULLIF(SUM(f.order_status = 'DELIVERED'), 0), 2) AS contribution_per_delivered,
  ROUND(100 * AVG(f.contribution < 0), 2)                     AS loss_making_pct,
  ROUND(AVG(f.delay_minutes), 1)                              AS avg_delay_minutes
FROM city ci
JOIN region st      ON st.region_id = ci.region_id
LEFT JOIN region zn ON zn.region_id = st.parent_region_id
LEFT JOIN v_order_financials f ON f.city_id = ci.city_id AND f.is_closed
GROUP BY ci.city_id, ci.city_name, st.region_name, zn.region_name;   -- Kochi stays, with 0 orders

-- ---------------------------------------------------------------------
-- 4. v_restaurant_scorecard
-- ---------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_restaurant_scorecard AS
SELECT
  r.restaurant_id, r.restaurant_name, ci.city_name, r.commission_pct, r.is_active,
  COUNT(f.order_id)                                           AS closed_orders,
  COALESCE(SUM(f.order_status = 'DELIVERED'), 0)              AS delivered_orders,
  ROUND(100 * AVG(f.order_status = 'CANCELLED'), 2)           AS cancel_rate_pct,
  COALESCE(SUM(f.revenue), 0)                                 AS revenue,
  COALESCE(SUM(f.contribution), 0)                            AS contribution,
  ROUND(SUM(f.contribution) / NULLIF(SUM(f.order_status = 'DELIVERED'), 0), 2) AS contribution_per_delivered,
  COALESCE(SUM(f.refund_loss), 0)                             AS refund_loss,
  ROUND(AVG(f.delay_minutes), 1)                              AS avg_delay_minutes,
  ROUND(100 * AVG(f.contribution < 0), 2)                     AS loss_making_pct
FROM restaurant r
JOIN city ci ON ci.city_id = r.city_id
LEFT JOIN v_order_financials f ON f.restaurant_id = r.restaurant_id AND f.is_closed
GROUP BY r.restaurant_id, r.restaurant_name, ci.city_name, r.commission_pct, r.is_active;

-- ---------------------------------------------------------------------
-- 5. v_coupon_performance: what each coupon costs the platform
--    (an order with two coupons appears under both)
-- ---------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_coupon_performance AS
SELECT
  cp.coupon_id, cp.coupon_code, k.campaign_name, cp.funded_by, cp.restaurant_share_pct,
  COUNT(du.order_id)                                          AS uses,
  COALESCE(SUM(du.discount_amount), 0)                        AS discount_given,
  ROUND(COALESCE(SUM(du.discount_amount * (1 - cp.restaurant_share_pct / 100)), 0), 2) AS platform_cost,
  ROUND(AVG(f.food_subtotal), 2)                              AS avg_food_subtotal,
  ROUND(AVG(f.contribution), 2)                               AS avg_order_contribution,
  ROUND(100 * AVG(f.contribution < 0), 2)                     AS loss_making_pct
FROM coupon cp
LEFT JOIN campaign k          ON k.campaign_id = cp.campaign_id
LEFT JOIN discount_usage du   ON du.coupon_id = cp.coupon_id
LEFT JOIN v_order_financials f ON f.order_id = du.order_id AND f.is_closed
GROUP BY cp.coupon_id, cp.coupon_code, k.campaign_name, cp.funded_by, cp.restaurant_share_pct;

-- ---------------------------------------------------------------------
-- 6. fn_order_contribution(order_id): same formula, one order.
--    READS SQL DATA: it reads tables but never changes them (required
--    with binary logging on). Returns NULL for an order that does not exist.
--    Intermediate values are DECIMAL(20,8) so nothing is rounded until the
--    end, exactly as in the view.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_order_contribution;
DELIMITER //
CREATE FUNCTION fn_order_contribution(p_order_id BIGINT UNSIGNED)
RETURNS DECIMAL(10,2)
READS SQL DATA
SQL SECURITY DEFINER
BEGIN
  DECLARE v_status        VARCHAR(20);
  DECLARE v_commission    DECIMAL(5,2);
  DECLARE v_fees          DECIMAL(20,8);
  DECLARE v_subtotal      DECIMAL(20,8);
  DECLARE v_revenue       DECIMAL(20,8) DEFAULT 0;
  DECLARE v_discount      DECIMAL(20,8) DEFAULT 0;
  DECLARE v_delivery      DECIMAL(20,8);
  DECLARE v_gateway       DECIMAL(20,8);
  DECLARE v_support       DECIMAL(20,8);
  DECLARE v_refund_loss   DECIMAL(20,8);
  DECLARE v_compensation  DECIMAL(20,8);

  SELECT o.order_status, r.commission_pct, o.delivery_fee + o.platform_fee + o.packaging_fee
    INTO v_status, v_commission, v_fees
    FROM orders o JOIN restaurant r ON r.restaurant_id = o.restaurant_id
   WHERE o.order_id = p_order_id;

  IF v_status IS NULL THEN
    RETURN NULL;                                   -- no such order
  END IF;

  SET v_subtotal = (SELECT COALESCE(SUM(quantity * unit_price), 0)
                    FROM order_item WHERE order_id = p_order_id);

  IF v_status <> 'CANCELLED' THEN
    SET v_revenue  = v_subtotal * v_commission / 100 + v_fees;
    SET v_discount = (SELECT COALESCE(SUM(du.discount_amount * (1 - cp.restaurant_share_pct / 100)), 0)
                      FROM discount_usage du JOIN coupon cp ON cp.coupon_id = du.coupon_id
                      WHERE du.order_id = p_order_id);
  END IF;

  SET v_delivery = (SELECT COALESCE(SUM(partner_payout + incentive_amount + wait_time_pay), 0)
                    FROM delivery_trip WHERE order_id = p_order_id);
  SET v_gateway  = (SELECT COALESCE(SUM(gateway_fee), 0)
                    FROM payment_transaction WHERE order_id = p_order_id);
  SET v_support  = (SELECT COALESCE(SUM(support_cost), 0)
                    FROM order_cost WHERE order_id = p_order_id);
  SET v_refund_loss = (SELECT COALESCE(SUM(refund_amount - recovered_amount), 0)
                       FROM refund
                       WHERE order_id = p_order_id
                         AND refund_status IN ('APPROVED', 'PROCESSED')
                         AND NOT (v_status = 'CANCELLED' AND refund_reason = 'CANCELLED'));
  SET v_compensation = (SELECT COALESCE(SUM(compensation_amount), 0)
                        FROM compensation WHERE order_id = p_order_id);

  RETURN ROUND(v_revenue - v_discount - v_delivery - v_gateway - v_support
               - v_refund_loss - v_compensation, 2);
END //
DELIMITER ;

-- ---------------------------------------------------------------------
-- 7. Privileges. Views and the function run with their DEFINER's rights,
--    so a role needs only the grant on the view/function itself, not on
--    the base tables behind it.
--    qb_admin already has ALL on quickbite.*.
-- ---------------------------------------------------------------------
GRANT SELECT ON quickbite.v_order_financials     TO qb_analyst;
GRANT SELECT ON quickbite.v_monthly_kpi          TO qb_analyst;
GRANT SELECT ON quickbite.v_city_scorecard       TO qb_analyst;
GRANT SELECT ON quickbite.v_restaurant_scorecard TO qb_analyst;
GRANT SELECT ON quickbite.v_coupon_performance   TO qb_analyst;
GRANT EXECUTE ON FUNCTION quickbite.fn_order_contribution TO qb_analyst;

-- Viewer dashboards: aggregates only, never order-level money.
GRANT SELECT ON quickbite.v_monthly_kpi          TO qb_viewer;
GRANT SELECT ON quickbite.v_city_scorecard       TO qb_viewer;
GRANT SELECT ON quickbite.v_restaurant_scorecard TO qb_viewer;
