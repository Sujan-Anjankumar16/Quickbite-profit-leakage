-- =====================================================================
--  QuickBite  -  tests/procedure_checks.sql   (Step 6)
--  Part A checks the LATEST detection run (run the procedures first, see README).
--  Part B tests every trigger inside one transaction that is rolled back;
--  statements marked EXPECT ERROR must fail, so run with --force:
--    docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --force -t quickbite' < db/mysql/tests/procedure_checks.sql
-- =====================================================================
USE quickbite;

SET @run = (SELECT detection_run_id FROM leakage_record
            ORDER BY detected_at DESC, leakage_record_id DESC LIMIT 1);
SELECT @run AS latest_run;

-- ---------------------------------------------------------------------
-- A. The detection run
-- ---------------------------------------------------------------------
-- A1. What leaked, by type (all rows, and primary rows only)
SELECT lt.leak_name,
       COUNT(*)                                  AS orders_with_leak,
       SUM(lr.leak_amount)                       AS leak_amount,
       SUM(lr.is_primary)                        AS primary_rows,
       SUM(IF(lr.is_primary, lr.leak_amount, 0)) AS primary_amount
FROM leakage_record lr JOIN leak_type lt ON lt.leak_type_id = lr.leak_type_id
WHERE lr.detection_run_id = @run
GROUP BY lt.leak_type_id, lt.leak_name
ORDER BY lt.leak_type_id;

-- A2. Exactly one primary leak on every order that has a leak, and it is the
--     largest one unless it was capped at the order's loss (expected 0, 0).
--     One pass with conditional aggregation: a correlated subquery here was
--     fine on warm statistics but took ~10 minutes right after a fresh bulk
--     load, when stale InnoDB statistics made MySQL pick a full scan per row.
SELECT 'A2 primary leak count' AS check_name,
       SUM(primaries <> 1) AS orders_without_exactly_one_primary,
       SUM(primary_amount < largest_other AND NOT capped) AS primary_not_the_largest
FROM (SELECT order_id,
             SUM(is_primary)                                              AS primaries,
             MAX(IF(is_primary, leak_amount, NULL))                       AS primary_amount,
             MAX(IF(is_primary, NULL, leak_amount))                       AS largest_other,
             MAX(is_primary AND explanation LIKE '%capped at order loss%') AS capped
      FROM leakage_record WHERE detection_run_id = @run GROUP BY order_id) x;

-- A3. Reconciliation: SUM(primary leaks on loss-making orders) <= their total loss
SELECT 'A3 reconciliation' AS check_name,
       SUM(lr.leak_amount)                          AS primary_leaks_on_loss_orders,
       (SELECT -SUM(contribution) FROM v_order_financials
        WHERE is_closed AND contribution < 0)       AS total_loss,
       SUM(lr.leak_amount) <= (SELECT -SUM(contribution) FROM v_order_financials
                               WHERE is_closed AND contribution < 0) AS holds,
       SUM(lr.leak_amount > -f.contribution)        AS orders_where_primary_exceeds_loss
FROM leakage_record lr
JOIN v_order_financials f ON f.order_id = lr.order_id
WHERE lr.detection_run_id = @run AND lr.is_primary AND f.contribution < 0;

-- A4. Leaks only on closed orders, only from active rules (expected 0, 0)
SELECT 'A4 scope' AS check_name,
       SUM(o.order_status NOT IN ('DELIVERED', 'CANCELLED')) AS leaks_on_open_orders,
       SUM(NOT ru.is_active)                                 AS leaks_from_inactive_rules
FROM leakage_record lr
JOIN orders o     ON o.order_id = lr.order_id
JOIN leak_rule ru ON ru.leak_rule_id = lr.leak_rule_id
WHERE lr.detection_run_id = @run;

-- A5. Primary leak causes on loss-making orders: where the loss comes from
SELECT lt.leak_name, COUNT(*) AS loss_orders, SUM(lr.leak_amount) AS explained_loss
FROM leakage_record lr
JOIN leak_type lt         ON lt.leak_type_id = lr.leak_type_id
JOIN v_order_financials f ON f.order_id = lr.order_id
WHERE lr.detection_run_id = @run AND lr.is_primary AND f.contribution < 0
GROUP BY lt.leak_name ORDER BY explained_loss DESC;

-- A6. The recommendations, best first (the planted leaks should lead)
SELECT recommendation_id, target_type, target_id, demand_risk, priority_score,
       estimated_saving, LEFT(recommendation_text, 110) AS recommendation
FROM recommendation WHERE status = 'NEW'
ORDER BY priority_score DESC
LIMIT 20;

-- A7. Every recommendation target is valid (expected 0)
SELECT 'A7 invalid targets' AS check_name,
       SUM(NOT fn_target_exists(target_type, target_id)) AS breakers
FROM recommendation;

-- ---------------------------------------------------------------------
-- B. Triggers (rolled back at the end)
-- ---------------------------------------------------------------------
START TRANSACTION;
SET @app_user_id = (SELECT user_id FROM app_user WHERE email = 'analyst@quickbite.dev');

-- B1. EXPECT ERROR: a customer referring themselves (UPDATE)
UPDATE customer SET referred_by_customer_id = customer_id WHERE customer_id = 100;

-- B2. EXPECT ERROR: a new (AUTO_INCREMENT) customer naming a referrer that does not exist
INSERT INTO customer (full_name, email, phone, referred_by_customer_id)
VALUES ('Loop Test', 'loop.test@example.com', '9000000000', 999999);

-- B3. EXPECT ERROR: a referral cycle (the referrer would become referred by their own referee)
SET @referee  = (SELECT MIN(customer_id) FROM customer WHERE referred_by_customer_id IS NOT NULL);
SET @referrer = (SELECT referred_by_customer_id FROM customer WHERE customer_id = @referee);
UPDATE customer SET referred_by_customer_id = @referee WHERE customer_id = @referrer;

-- B4. EXPECT ERROR: recommendation pointing at a restaurant that does not exist
INSERT INTO recommendation (target_type, target_id, recommendation_text, demand_risk, priority_score)
VALUES ('RESTAURANT', 999999, 'bad target', 'LOW', 10);

-- B5. a valid target is accepted
INSERT INTO recommendation (target_type, target_id, recommendation_text, demand_risk, priority_score)
VALUES ('CITY', 1, 'trigger test', 'LOW', 10);
SET @reco = LAST_INSERT_ID();

-- B6. EXPECT ERROR: NEW -> IMPLEMENTED skips ACCEPTED
UPDATE recommendation SET status = 'IMPLEMENTED' WHERE recommendation_id = @reco;

-- B7. NEW -> ACCEPTED -> IMPLEMENTED works, and each move is audited
UPDATE recommendation SET status = 'ACCEPTED'    WHERE recommendation_id = @reco;
UPDATE recommendation SET status = 'IMPLEMENTED' WHERE recommendation_id = @reco;

-- B8. EXPECT ERROR: IMPLEMENTED is final
UPDATE recommendation SET status = 'NEW' WHERE recommendation_id = @reco;

-- B9. leak rule tuning is audited with old and new values
UPDATE leak_rule SET threshold_value = 12 WHERE leak_rule_id = 1;

-- B10. a password change is audited without the hash
UPDATE app_user SET password_hash = CONCAT(password_hash, 'x') WHERE email = 'viewer@quickbite.dev';

-- B11. EXPECT ERROR: procedure argument check
CALL sp_detect_leaks('2026-06-01', '2026-01-01', @r, @n);

SELECT 'B audit rows written in this test' AS check_name,
       entity_name, entity_id, action_name, actor_user_id,
       old_values, new_values
FROM audit_log
WHERE audit_log_id > (SELECT COALESCE(MAX(audit_log_id), 0) - 10 FROM audit_log)
  AND actor_user_id = @app_user_id
ORDER BY audit_log_id;

ROLLBACK;
SET @app_user_id = NULL;
SELECT COUNT(*) AS test_recommendations_left FROM recommendation
WHERE recommendation_text = 'trigger test';                                -- 0
