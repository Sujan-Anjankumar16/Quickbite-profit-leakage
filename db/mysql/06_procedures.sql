-- =====================================================================
--  QuickBite  -  06_procedures.sql
--  Functions, triggers, stored procedures and CTEs
--  (rubric item 4: "procedures/functions, triggers, CTEs", 6 marks)
--
--  Functions
--    fn_delivery_allowance(km, peak_or_rain)  benchmark delivery cost from leak_rule JSON
--    fn_target_exists(target_type, target_id) validates the polymorphic recommendation target
--  Triggers
--    customer        BEFORE INSERT / UPDATE  no self-referral, no referral cycle (recursive CTE)
--    recommendation  BEFORE INSERT / UPDATE  target must exist; status may only move forward
--    recommendation  AFTER UPDATE            audit status changes
--    leak_rule       AFTER INSERT / UPDATE   audit rule tuning
--    app_user        AFTER INSERT / UPDATE   audit user changes (never the password hash)
--  Procedures
--    sp_detect_leaks(from, to, OUT run_id, OUT leaks)          six leak rules, one CTE pipeline
--    sp_generate_recommendations(run_id, OUT recommendations)  ranked actions from a run
--
--  Audit rows take actor_user_id from the session variable @app_user_id
--  (the API sets it after login; NULL for scripts and system jobs).
--  Audit triggers sit only on low-volume tables, so loading 60,000 orders
--  does not write 60,000 audit rows.
--
--  Re-runnable. Apply by hand:
--    docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" quickbite' < db/mysql/06_procedures.sql
-- =====================================================================
USE quickbite;

DROP FUNCTION  IF EXISTS fn_delivery_allowance;
DROP FUNCTION  IF EXISTS fn_target_exists;
DROP TRIGGER   IF EXISTS trg_customer_bi;
DROP TRIGGER   IF EXISTS trg_customer_bu;
DROP TRIGGER   IF EXISTS trg_recommendation_bi;
DROP TRIGGER   IF EXISTS trg_recommendation_bu;
DROP TRIGGER   IF EXISTS trg_recommendation_au;
DROP TRIGGER   IF EXISTS trg_leak_rule_ai;
DROP TRIGGER   IF EXISTS trg_leak_rule_au;
DROP TRIGGER   IF EXISTS trg_app_user_ai;
DROP TRIGGER   IF EXISTS trg_app_user_au;
DROP PROCEDURE IF EXISTS sp_detect_leaks;
DROP PROCEDURE IF EXISTS sp_generate_recommendations;

DELIMITER //

-- =====================================================================
--  1. FUNCTIONS
-- =====================================================================

-- Allowed partner payout + incentive for a trip: (base_pay + per_km * km)
-- * (1 + tolerance_pct / 100), read from rule 3 (normal) or rule 4 (peak or
-- rain). Returns NULL when that rule is switched off, so no leak is found.
CREATE FUNCTION fn_delivery_allowance(p_km DECIMAL(5,2), p_peak_or_rain BOOLEAN)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
  DECLARE v_cfg JSON;
  SET v_cfg = (SELECT rule_config FROM leak_rule
               WHERE leak_rule_id = IF(p_peak_or_rain, 4, 3) AND is_active);
  IF v_cfg IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN ROUND((CAST(v_cfg->>'$.base_pay' AS DECIMAL(10,2))
                + CAST(v_cfg->>'$.per_km' AS DECIMAL(10,2)) * p_km)
               * (1 + CAST(v_cfg->>'$.tolerance_pct' AS DECIMAL(10,2)) / 100), 2);
END //

-- TRUE when target_id exists in the table named by target_type.
-- GLOBAL is valid only with a NULL id (the CHECK constraint says the same).
CREATE FUNCTION fn_target_exists(p_type VARCHAR(20), p_id INT UNSIGNED)
RETURNS BOOLEAN
READS SQL DATA
BEGIN
  RETURN CASE p_type
    WHEN 'GLOBAL'           THEN p_id IS NULL
    WHEN 'REGION'           THEN EXISTS (SELECT 1 FROM region           WHERE region_id     = p_id)
    WHEN 'CITY'             THEN EXISTS (SELECT 1 FROM city             WHERE city_id       = p_id)
    WHEN 'RESTAURANT'       THEN EXISTS (SELECT 1 FROM restaurant       WHERE restaurant_id = p_id)
    WHEN 'COUPON'           THEN EXISTS (SELECT 1 FROM coupon           WHERE coupon_id     = p_id)
    WHEN 'CAMPAIGN'         THEN EXISTS (SELECT 1 FROM campaign         WHERE campaign_id   = p_id)
    WHEN 'DELIVERY_PARTNER' THEN EXISTS (SELECT 1 FROM delivery_partner WHERE partner_id    = p_id)
    ELSE FALSE
  END;
END //

-- =====================================================================
--  2. TRIGGERS
-- =====================================================================

-- A customer cannot refer themselves (this could not be a CHECK: MySQL
-- forbids CHECK on an AUTO_INCREMENT column).
-- With an AUTO_INCREMENT insert, NEW.customer_id is still 0 here, so the
-- only way to point at yourself is to name an id that does not exist yet:
-- the referrer must already exist.
CREATE TRIGGER trg_customer_bi
BEFORE INSERT ON customer
FOR EACH ROW
BEGIN
  IF NEW.referred_by_customer_id IS NOT NULL THEN
    IF NEW.referred_by_customer_id = NEW.customer_id
       OR (NEW.customer_id = 0
           AND NOT EXISTS (SELECT 1 FROM customer WHERE customer_id = NEW.referred_by_customer_id)) THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'A customer cannot refer themselves (referrer must be an existing, different customer)';
    END IF;
  END IF;
END //

-- On UPDATE, also refuse a referral CYCLE (A refers B, B refers A ...):
-- a recursive CTE walks up the chain from the new referrer; if it reaches
-- this customer, the change would close a loop.
CREATE TRIGGER trg_customer_bu
BEFORE UPDATE ON customer
FOR EACH ROW
BEGIN
  DECLARE v_loop INT DEFAULT 0;
  IF NEW.referred_by_customer_id IS NOT NULL
     AND NOT (NEW.referred_by_customer_id <=> OLD.referred_by_customer_id) THEN
    IF NEW.referred_by_customer_id = NEW.customer_id THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A customer cannot refer themselves';
    END IF;
    WITH RECURSIVE up_chain AS (
      SELECT customer_id, referred_by_customer_id, 1 AS depth
      FROM customer WHERE customer_id = NEW.referred_by_customer_id
      UNION ALL
      SELECT c.customer_id, c.referred_by_customer_id, u.depth + 1
      FROM customer c JOIN up_chain u ON c.customer_id = u.referred_by_customer_id
      WHERE u.depth < 100
    )
    SELECT COUNT(*) INTO v_loop FROM up_chain WHERE customer_id = NEW.customer_id;
    IF v_loop > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Referral cycle: this customer is already above the new referrer in the chain';
    END IF;
  END IF;
END //

-- recommendation.target_id is polymorphic, so it cannot be a FOREIGN KEY;
-- this trigger does the FK's job.
CREATE TRIGGER trg_recommendation_bi
BEFORE INSERT ON recommendation
FOR EACH ROW
BEGIN
  DECLARE v_msg VARCHAR(255);
  IF NOT fn_target_exists(NEW.target_type, NEW.target_id) THEN
    SET v_msg = CONCAT('Recommendation target ', NEW.target_type, ' ', COALESCE(NEW.target_id, 'NULL'),
                       ' does not exist');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;
  IF NEW.status <> 'NEW' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A new recommendation must start with status NEW';
  END IF;
END //

-- Allowed status moves: NEW -> ACCEPTED | REJECTED, ACCEPTED -> IMPLEMENTED | REJECTED.
-- REJECTED and IMPLEMENTED are final.
CREATE TRIGGER trg_recommendation_bu
BEFORE UPDATE ON recommendation
FOR EACH ROW
BEGIN
  DECLARE v_msg VARCHAR(255);
  IF NOT (NEW.target_type <=> OLD.target_type AND NEW.target_id <=> OLD.target_id)
     AND NOT fn_target_exists(NEW.target_type, NEW.target_id) THEN
    SET v_msg = CONCAT('Recommendation target ', NEW.target_type, ' ', COALESCE(NEW.target_id, 'NULL'),
                       ' does not exist');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;
  IF NEW.status <> OLD.status AND NOT (
       (OLD.status = 'NEW'      AND NEW.status IN ('ACCEPTED', 'REJECTED'))
    OR (OLD.status = 'ACCEPTED' AND NEW.status IN ('IMPLEMENTED', 'REJECTED'))) THEN
    SET v_msg = CONCAT('Recommendation status cannot change from ', OLD.status, ' to ', NEW.status);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;
END //

CREATE TRIGGER trg_recommendation_au
AFTER UPDATE ON recommendation
FOR EACH ROW
BEGIN
  IF NEW.status <> OLD.status THEN
    INSERT INTO audit_log (actor_user_id, entity_name, entity_id, action_name, old_values, new_values)
    VALUES (@app_user_id, 'recommendation', NEW.recommendation_id, 'UPDATE',
            JSON_OBJECT('status', OLD.status), JSON_OBJECT('status', NEW.status));
  END IF;
END //

CREATE TRIGGER trg_leak_rule_ai
AFTER INSERT ON leak_rule
FOR EACH ROW
BEGIN
  INSERT INTO audit_log (actor_user_id, entity_name, entity_id, action_name, new_values)
  VALUES (@app_user_id, 'leak_rule', NEW.leak_rule_id, 'INSERT',
          JSON_OBJECT('rule_name', NEW.rule_name, 'threshold_value', NEW.threshold_value,
                      'rule_config', NEW.rule_config, 'is_active', NEW.is_active));
END //

CREATE TRIGGER trg_leak_rule_au
AFTER UPDATE ON leak_rule
FOR EACH ROW
BEGIN
  INSERT INTO audit_log (actor_user_id, entity_name, entity_id, action_name, old_values, new_values)
  VALUES (@app_user_id, 'leak_rule', NEW.leak_rule_id, 'UPDATE',
          JSON_OBJECT('threshold_value', OLD.threshold_value, 'rule_config', OLD.rule_config,
                      'is_active', OLD.is_active),
          JSON_OBJECT('threshold_value', NEW.threshold_value, 'rule_config', NEW.rule_config,
                      'is_active', NEW.is_active));
END //

CREATE TRIGGER trg_app_user_ai
AFTER INSERT ON app_user
FOR EACH ROW
BEGIN
  INSERT INTO audit_log (actor_user_id, entity_name, entity_id, action_name, new_values)
  VALUES (@app_user_id, 'app_user', NEW.user_id, 'INSERT',
          JSON_OBJECT('email', NEW.email, 'role_id', NEW.role_id, 'is_active', NEW.is_active));
END //

CREATE TRIGGER trg_app_user_au
AFTER UPDATE ON app_user
FOR EACH ROW
BEGIN
  -- password_hash is never copied into the log; only the fact that it changed.
  INSERT INTO audit_log (actor_user_id, entity_name, entity_id, action_name, old_values, new_values)
  VALUES (@app_user_id, 'app_user', NEW.user_id, 'UPDATE',
          JSON_OBJECT('email', OLD.email, 'role_id', OLD.role_id, 'is_active', OLD.is_active),
          JSON_OBJECT('email', NEW.email, 'role_id', NEW.role_id, 'is_active', NEW.is_active,
                      'password_changed', NOT (NEW.password_hash <=> OLD.password_hash)));
END //

-- =====================================================================
--  3. sp_detect_leaks
--  For every CLOSED order placed in [p_from, p_to), measure each leak type
--  as COST IN EXCESS OF ITS BENCHMARK (never the whole cost), using only
--  ACTIVE rules and their current thresholds:
--    1 DISCOUNT_OVERSPEND   rule 1: platform discount above threshold% of subtotal
--                           rule 2: platform discount of every coupon after the
--                                   largest, when more than threshold coupons are used
--                           (one row per type: the larger of the two)
--    2 DELIVERY_COST_OVERRUN payout + incentive above fn_delivery_allowance (rules 3/4)
--    3 DELAY_COST           wait_time_pay + DELAY_VOUCHER compensation on orders
--                           more than threshold minutes late (rule 5)
--    4 UNRECOVERED_REFUND   refund loss minus delay vouchers, above threshold (rule 6)
--    5 GATEWAY_FEE_EXCESS   gateway fee above threshold% of the amount (rule 7)
--    6 LOW_VALUE_ORDER      loss of a delivered order with subtotal below threshold (rule 8)
--  The largest leak on an order is its PRIMARY leak. On a loss-making order
--  the primary leak is capped at the order's loss, so the reconciliation rule
--  holds: SUM(primary leaks on loss-making orders) <= their total loss.
--  Each call is a new run (history is kept); one transaction per run.
--  Note: its START TRANSACTION commits any transaction the caller had open.
-- =====================================================================
CREATE PROCEDURE sp_detect_leaks(IN  p_from DATE,
                                 IN  p_to   DATE,
                                 OUT p_run_id VARCHAR(40),
                                 OUT p_leaks  INT)
MODIFIES SQL DATA
detect: BEGIN
  -- Arguments are checked BEFORE the error handler exists, so a bad call
  -- fails without the handler's ROLLBACK touching the caller's transaction.
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_detect_leaks: p_to must be after p_from';
  END IF;

  BEGIN
  DECLARE v_disc_pct    DECIMAL(10,2);
  DECLARE v_max_coupon  DECIMAL(10,2);
  DECLARE v_delay_grace DECIMAL(10,2);
  DECLARE v_refund_min  DECIMAL(10,2);
  DECLARE v_gw_pct      DECIMAL(10,2);
  DECLARE v_low_max     DECIMAL(10,2);

  -- From here on, any error undoes this run's half-written rows.
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET p_run_id = CONCAT('run-', DATE_FORMAT(NOW(6), '%Y%m%d-%H%i%s-%f'));

  -- current settings; NULL = rule switched off
  SET v_disc_pct   = (SELECT threshold_value FROM leak_rule WHERE leak_rule_id = 1 AND is_active);
  SET v_max_coupon = (SELECT threshold_value FROM leak_rule WHERE leak_rule_id = 2 AND is_active);
  SET v_delay_grace = (SELECT threshold_value FROM leak_rule WHERE leak_rule_id = 5 AND is_active);
  SET v_refund_min = (SELECT threshold_value FROM leak_rule WHERE leak_rule_id = 6 AND is_active);
  SET v_gw_pct     = (SELECT threshold_value FROM leak_rule WHERE leak_rule_id = 7 AND is_active);
  SET v_low_max    = (SELECT threshold_value FROM leak_rule WHERE leak_rule_id = 8 AND is_active);

  START TRANSACTION;

  INSERT INTO leakage_record (order_id, leak_type_id, leak_rule_id, leak_amount, is_primary,
                              detection_run_id, explanation)
  WITH
  base AS (                                   -- closed orders in the window
    SELECT f.order_id, f.order_status, f.cancellation_stage, f.food_subtotal,
           f.platform_discount, f.refund_loss, f.contribution, f.delay_minutes,
           f.distance_km, (f.is_peak_period OR f.is_rainy_weather) AS peak_or_rain
    FROM v_order_financials f
    WHERE f.is_closed AND f.order_time >= p_from AND f.order_time < p_to
  ),
  coupon_parts AS (                           -- platform share of each coupon on each order
    SELECT du.order_id, du.discount_amount * (1 - c.restaurant_share_pct / 100) AS platform_part
    FROM discount_usage du
    JOIN coupon c ON c.coupon_id = du.coupon_id
    JOIN base b   ON b.order_id  = du.order_id AND b.order_status = 'DELIVERED'
  ),
  delay_vouchers AS (
    SELECT cm.order_id, SUM(cm.compensation_amount) AS vouchers
    FROM compensation cm JOIN base b ON b.order_id = cm.order_id
    WHERE cm.reason = 'DELAY_VOUCHER'
    GROUP BY cm.order_id
  ),
  candidates AS (
    -- 1a. discount above the benchmark share of the subtotal
    SELECT b.order_id, 1 AS leak_type_id, 1 AS leak_rule_id,
           b.platform_discount - b.food_subtotal * v_disc_pct / 100 AS excess,
           CONCAT('Platform discount ', b.platform_discount, ' exceeds ', v_disc_pct,
                  '% of subtotal ', b.food_subtotal) AS explanation
    FROM base b
    WHERE v_disc_pct IS NOT NULL AND b.order_status = 'DELIVERED'
    UNION ALL
    -- 1b. coupon stacking: every coupon after the largest is excess
    SELECT cp.order_id, 1, 2,
           SUM(cp.platform_part) - MAX(cp.platform_part),
           CONCAT(COUNT(*), ' coupons stacked on one order')
    FROM coupon_parts cp
    WHERE v_max_coupon IS NOT NULL
    GROUP BY cp.order_id
    HAVING COUNT(*) > v_max_coupon
    UNION ALL
    -- 2. delivery cost above the distance benchmark (wait pay belongs to type 3)
    SELECT b.order_id, 2, IF(b.peak_or_rain, 4, 3),
           t.partner_payout + t.incentive_amount - fn_delivery_allowance(b.distance_km, b.peak_or_rain),
           CONCAT('Payout + incentive ', t.partner_payout + t.incentive_amount, ' vs allowance ',
                  fn_delivery_allowance(b.distance_km, b.peak_or_rain), ' for ', b.distance_km, ' km',
                  IF(b.peak_or_rain, ' (peak or rain)', ''))
    FROM base b JOIN delivery_trip t ON t.order_id = b.order_id
    WHERE b.order_status = 'DELIVERED' OR b.cancellation_stage = 'AFTER_PICKUP'
    UNION ALL
    -- 3. delay cost: partner wait-time pay + delay vouchers, only on orders
    --    delivered more than the grace minutes late (rule 5 threshold)
    SELECT b.order_id, 3, 5,
           t.wait_time_pay + COALESCE(dv.vouchers, 0),
           CONCAT('Wait-time pay ', t.wait_time_pay, ' + delay vouchers ', COALESCE(dv.vouchers, 0),
                  '; delivered ', COALESCE(b.delay_minutes, 0), ' min vs promise')
    FROM base b
    JOIN delivery_trip t        ON t.order_id  = b.order_id
    LEFT JOIN delay_vouchers dv ON dv.order_id = b.order_id
    WHERE v_delay_grace IS NOT NULL AND b.order_status = 'DELIVERED'
      AND b.delay_minutes > v_delay_grace
    UNION ALL
    -- 4. unrecovered refunds and non-delay compensation
    SELECT b.order_id, 4, 6,
           b.refund_loss - COALESCE(dv.vouchers, 0),
           CONCAT('Unrecovered refunds/compensation ', b.refund_loss - COALESCE(dv.vouchers, 0))
    FROM base b LEFT JOIN delay_vouchers dv ON dv.order_id = b.order_id
    WHERE v_refund_min IS NOT NULL
      AND b.refund_loss - COALESCE(dv.vouchers, 0) > v_refund_min
    UNION ALL
    -- 5. gateway fee above the benchmark rate
    SELECT p.order_id, 5, 7,
           SUM(GREATEST(p.gateway_fee - p.transaction_amount * v_gw_pct / 100, 0)),
           CONCAT(MAX(p.gateway_name), ' fee ', SUM(p.gateway_fee), ' exceeds ', v_gw_pct, '% of ',
                  SUM(p.transaction_amount))
    FROM payment_transaction p JOIN base b ON b.order_id = p.order_id
    WHERE v_gw_pct IS NOT NULL AND p.payment_status = 'SUCCESS'
    GROUP BY p.order_id
    UNION ALL
    -- 6. small basket that lost money
    SELECT b.order_id, 6, 8,
           -b.contribution,
           CONCAT('Basket ', b.food_subtotal, ' below ', v_low_max, ' lost ', -b.contribution)
    FROM base b
    WHERE v_low_max IS NOT NULL AND b.order_status = 'DELIVERED'
      AND b.food_subtotal < v_low_max AND b.contribution < 0
  ),
  per_type AS (                               -- one row per (order, leak type): the larger rule
    SELECT c.*, ROW_NUMBER() OVER (PARTITION BY c.order_id, c.leak_type_id
                                   ORDER BY c.excess DESC, c.leak_rule_id) AS rn_type
    FROM candidates c
    WHERE ROUND(c.excess, 2) > 0
  ),
  ranked AS (                                 -- the largest leak on the order is primary
    SELECT p.*, ROW_NUMBER() OVER (PARTITION BY p.order_id
                                   ORDER BY p.excess DESC, p.leak_type_id) AS rn_order
    FROM per_type p
    WHERE p.rn_type = 1
  )
  SELECT r.order_id, r.leak_type_id, r.leak_rule_id,
         IF(r.rn_order = 1 AND b.contribution < 0,
            LEAST(ROUND(r.excess, 2), -b.contribution),
            ROUND(r.excess, 2)),
         r.rn_order = 1,
         p_run_id,
         LEFT(IF(r.rn_order = 1 AND b.contribution < 0 AND ROUND(r.excess, 2) > -b.contribution,
                 CONCAT(r.explanation, ' (capped at order loss ', -b.contribution, ')'),
                 r.explanation), 255)
  FROM ranked r JOIN base b ON b.order_id = r.order_id;

  SET p_leaks = ROW_COUNT();

  INSERT INTO audit_log (actor_user_id, entity_name, entity_id, action_name, new_values)
  VALUES (@app_user_id, 'leakage_record', p_run_id, 'RUN',
          JSON_OBJECT('procedure', 'sp_detect_leaks', 'from', p_from, 'to', p_to, 'leaks', p_leaks));

  COMMIT;
  END;
END detect //

-- =====================================================================
--  4. sp_generate_recommendations
--  Turns one detection run into ranked actions. Each leak type is grouped
--  by the target that can fix it:
--    1 -> COUPON (the coupon with the largest platform share on the order)
--    2 -> DELIVERY_PARTNER (rule 3, normal) and CITY (rule 4, peak or rain)
--    3, 4 -> RESTAURANT
--    5 -> GLOBAL, one per gateway     6 -> CITY
--  estimated_saving = leak in the run window x share judged recoverable;
--  demand_risk is the risk the fix costs orders; priority_score (0-100)
--  ranks saving discounted by risk. Top 10 targets per type and target kind, saving >= 500.
--  Recommendations still in status NEW are replaced; ACCEPTED, REJECTED
--  and IMPLEMENTED ones are kept as history.
-- =====================================================================
CREATE PROCEDURE sp_generate_recommendations(IN  p_run_id VARCHAR(40),
                                             OUT p_count  INT)
MODIFIES SQL DATA
recommend: BEGIN
  IF NOT EXISTS (SELECT 1 FROM leakage_record WHERE detection_run_id = p_run_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_generate_recommendations: unknown or empty detection run';
  END IF;

  BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  DELETE FROM recommendation WHERE status = 'NEW';

  INSERT INTO recommendation (leak_type_id, target_type, target_id, recommendation_text,
                              estimated_saving, demand_risk, priority_score)
  WITH
  leaks AS (
    SELECT lr.order_id, lr.leak_type_id, lr.leak_rule_id, lr.leak_amount, o.restaurant_id, r.city_id
    FROM leakage_record lr
    JOIN orders o     ON o.order_id = lr.order_id
    JOIN restaurant r ON r.restaurant_id = o.restaurant_id
    WHERE lr.detection_run_id = p_run_id
  ),
  by_target AS (
    SELECT 1 AS leak_type_id, 'COUPON' AS target_type, tc.coupon_id AS target_id,
           CAST(NULL AS CHAR(30)) AS gateway, SUM(l.leak_amount) AS leak, COUNT(*) AS orders
    FROM leaks l
    JOIN LATERAL (SELECT du.coupon_id
                  FROM discount_usage du JOIN coupon c ON c.coupon_id = du.coupon_id
                  WHERE du.order_id = l.order_id
                  ORDER BY du.discount_amount * (1 - c.restaurant_share_pct / 100) DESC, du.coupon_id
                  LIMIT 1) AS tc
    WHERE l.leak_type_id = 1
    GROUP BY tc.coupon_id
    UNION ALL
    SELECT 2, 'DELIVERY_PARTNER', t.partner_id, NULL, SUM(l.leak_amount), COUNT(*)
    FROM leaks l JOIN delivery_trip t ON t.order_id = l.order_id
    WHERE l.leak_type_id = 2 AND l.leak_rule_id = 3           -- normal conditions: partner payout slab
    GROUP BY t.partner_id
    UNION ALL
    SELECT 2, 'CITY', l.city_id, NULL, SUM(l.leak_amount), COUNT(*)
    FROM leaks l
    WHERE l.leak_type_id = 2 AND l.leak_rule_id = 4           -- peak or rain: the city's incentive policy
    GROUP BY l.city_id
    UNION ALL
    SELECT l.leak_type_id, 'RESTAURANT', l.restaurant_id, NULL, SUM(l.leak_amount), COUNT(*)
    FROM leaks l
    WHERE l.leak_type_id IN (3, 4)
    GROUP BY l.leak_type_id, l.restaurant_id
    UNION ALL
    SELECT 5, 'GLOBAL', NULL, p.gateway_name, SUM(l.leak_amount), COUNT(*)
    FROM leaks l
    JOIN payment_transaction p ON p.order_id = l.order_id AND p.payment_status = 'SUCCESS'
    WHERE l.leak_type_id = 5
    GROUP BY p.gateway_name
    UNION ALL
    SELECT 6, 'CITY', l.city_id, NULL, SUM(l.leak_amount), COUNT(*)
    FROM leaks l
    WHERE l.leak_type_id = 6
    GROUP BY l.city_id
  ),
  scored AS (
    SELECT bt.*,
           ROUND(bt.leak * CASE bt.leak_type_id WHEN 1 THEN 0.60 WHEN 2 THEN 0.90 WHEN 3 THEN 0.50
                                                WHEN 4 THEN 0.80 WHEN 5 THEN 1.00 ELSE 0.50 END, 2) AS saving,
           CASE bt.leak_type_id WHEN 1 THEN 'HIGH' WHEN 3 THEN 'MEDIUM' WHEN 6 THEN 'MEDIUM'
                                ELSE 'LOW' END AS demand_risk,
           ROW_NUMBER() OVER (PARTITION BY bt.leak_type_id, bt.target_type ORDER BY bt.leak DESC) AS rn
    FROM by_target bt
  ),
  kept AS (
    SELECT s.*,
           s.saving * CASE s.demand_risk WHEN 'LOW' THEN 1.0 WHEN 'MEDIUM' THEN 0.8 ELSE 0.6 END AS weighted
    FROM scored s
    WHERE s.rn <= 10 AND s.saving >= 500
  )
  SELECT k.leak_type_id, k.target_type, k.target_id,
         LEFT(CASE k.leak_type_id
           WHEN 1 THEN CONCAT('Cap or retire coupon ', cp.coupon_code, ': ', k.orders,
                              ' orders gave Rs ', ROUND(k.leak), ' of platform discount above the benchmark.')
           WHEN 2 THEN IF(k.target_type = 'CITY',
                          CONCAT('Review peak and rain incentives in ', ct.city_name, ': ', k.orders,
                                 ' trips cost Rs ', ROUND(k.leak), ' above the peak/rain allowance.'),
                          CONCAT('Review the payout slab of partner ', dp.partner_name, ' (', pc.city_name, '): ',
                                 k.orders, ' trips cost Rs ', ROUND(k.leak), ' above the distance benchmark.'))
           WHEN 3 THEN CONCAT('Fix preparation times at ', rs.restaurant_name, ' (', rc.city_name, '): Rs ',
                              ROUND(k.leak), ' of wait-time pay and delay vouchers on ', k.orders, ' orders.')
           WHEN 4 THEN CONCAT('Enforce refund charge-back for ', rs.restaurant_name, ' (', rc.city_name, '): Rs ',
                              ROUND(k.leak), ' unrecovered on ', k.orders, ' orders.')
           WHEN 5 THEN CONCAT('Renegotiate or reroute gateway ', k.gateway, ': Rs ', ROUND(k.leak),
                              ' of fees above the benchmark rate on ', k.orders, ' payments.')
           ELSE        CONCAT('Add a minimum basket or small-order fee in ', ct.city_name, ': ', k.orders,
                              ' small orders lost Rs ', ROUND(k.leak), '.')
         END, 500),
         k.saving,
         k.demand_risk,
         ROUND(100 * k.weighted / MAX(k.weighted) OVER (), 2)
  FROM kept k
  LEFT JOIN coupon cp            ON k.target_type = 'COUPON'           AND cp.coupon_id     = k.target_id
  LEFT JOIN delivery_partner dp  ON k.target_type = 'DELIVERY_PARTNER' AND dp.partner_id    = k.target_id
  LEFT JOIN city pc              ON pc.city_id = dp.city_id
  LEFT JOIN restaurant rs        ON k.target_type = 'RESTAURANT'       AND rs.restaurant_id = k.target_id
  LEFT JOIN city rc              ON rc.city_id = rs.city_id
  LEFT JOIN city ct              ON k.target_type = 'CITY'             AND ct.city_id       = k.target_id;

  SET p_count = ROW_COUNT();

  INSERT INTO audit_log (actor_user_id, entity_name, entity_id, action_name, new_values)
  VALUES (@app_user_id, 'recommendation', p_run_id, 'RUN',
          JSON_OBJECT('procedure', 'sp_generate_recommendations', 'recommendations', p_count));

  COMMIT;
  END;
END recommend //

DELIMITER ;

-- =====================================================================
--  5. Privileges. Procedures run with their DEFINER's rights, so an analyst
--     can run detection without INSERT rights on leakage_record itself.
-- =====================================================================
GRANT EXECUTE ON PROCEDURE quickbite.sp_detect_leaks             TO qb_analyst;
GRANT EXECUTE ON PROCEDURE quickbite.sp_generate_recommendations TO qb_analyst;
GRANT EXECUTE ON FUNCTION  quickbite.fn_delivery_allowance       TO qb_analyst;
