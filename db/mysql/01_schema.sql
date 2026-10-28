-- =====================================================================
--  QuickBite Profit Leakage Analyzer
--  01_schema.sql  -  DDL for MySQL 8.4 (rubric: "SQL DDL with constraints")
--
--  Built from the relational schema (23 relations), which came from the
--  ER diagram by the 7-step mapping algorithm. Each table header says
--  which mapping step produced it.
--
--  Conventions used everywhere:
--    pk_  primary key        fk_<table>_<column>  foreign key
--    uq_  unique             chk_<table>_<rule>   check constraint
--    ix_  ordinary index
--  Named constraints make error messages readable, e.g.
--    "Check constraint 'chk_refund_recovered_le_refund' is violated."
--
--  Money is DECIMAL(10,2): exact, unlike FLOAT/DOUBLE.
--  Categorical values use VARCHAR + CHECK ... IN (...) instead of ENUM, so
--  every allowed value is visible as a constraint (and easy to extend).
--
--  Derived attributes from the ER diagram are NOT stored (mapping rule):
--    food_subtotal, GMV, delay_minutes, platform_discount_amount,
--    refund_loss_amount, contribution_amount  -> computed in views/functions.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS quickbite
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE quickbite;

-- Re-runnable: drop children before parents.
SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS audit_log, app_user, app_role,
  recommendation, leakage_record, leak_rule, leak_type,
  discount_usage, coupon, campaign,
  compensation, refund, payment_transaction, delivery_trip,
  order_cost, order_item, orders,
  delivery_partner, menu_item, restaurant, customer, city, region;
SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
--  A. LOCATION HIERARCHY
-- =====================================================================

-- REGION  (Step 1: strong entity; Step 4: recursive 1:N PART_OF -> self-FK)
CREATE TABLE region (
  region_id         INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  region_name       VARCHAR(80)   NOT NULL,
  region_type       VARCHAR(20)   NOT NULL,
  parent_region_id  INT UNSIGNED  NULL,          -- partial participation -> nullable
  CONSTRAINT pk_region PRIMARY KEY (region_id),
  CONSTRAINT uq_region_name UNIQUE (region_name),
  CONSTRAINT chk_region_type CHECK (region_type IN ('COUNTRY', 'STATE', 'ZONE')),
  CONSTRAINT fk_region_parent FOREIGN KEY (parent_region_id)
    REFERENCES region (region_id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE = InnoDB;

-- CITY  (Step 1; Step 4: LOCATED_IN, REGION 1 : CITY N, total on CITY -> NOT NULL)
CREATE TABLE city (
  city_id     INT UNSIGNED NOT NULL AUTO_INCREMENT,
  region_id   INT UNSIGNED NOT NULL,
  city_name   VARCHAR(80)  NOT NULL,
  timezone    VARCHAR(40)  NOT NULL DEFAULT 'Asia/Kolkata',
  is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
  CONSTRAINT pk_city PRIMARY KEY (city_id),
  CONSTRAINT uq_city_region_name UNIQUE (region_id, city_name),
  CONSTRAINT fk_city_region FOREIGN KEY (region_id)
    REFERENCES region (region_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;


-- =====================================================================
--  B. PEOPLE AND PLACES
-- =====================================================================

-- CUSTOMER  (Step 1; Step 4: recursive REFERS -> referred_by_customer_id)
-- Note: "a customer cannot refer themselves" is NOT a CHECK here, because
-- MySQL forbids CHECK on an AUTO_INCREMENT column. A trigger enforces it later.
CREATE TABLE customer (
  customer_id              INT UNSIGNED NOT NULL AUTO_INCREMENT,
  full_name                VARCHAR(100) NOT NULL,
  email                    VARCHAR(120) NOT NULL,
  phone                    VARCHAR(15)  NOT NULL,
  referred_by_customer_id  INT UNSIGNED NULL,      -- Referee side is partial
  created_at               DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_customer PRIMARY KEY (customer_id),
  CONSTRAINT uq_customer_email UNIQUE (email),     -- candidate key -> UNIQUE (Step 1)
  CONSTRAINT chk_customer_email CHECK (email LIKE '%_@_%._%'),
  CONSTRAINT chk_customer_phone CHECK (phone REGEXP '^[0-9+][0-9]{9,14}$'),
  CONSTRAINT fk_customer_referrer FOREIGN KEY (referred_by_customer_id)
    REFERENCES customer (customer_id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE = InnoDB;

-- RESTAURANT  (Step 1; Step 4: HOSTS, CITY 1 : RESTAURANT N, total)
CREATE TABLE restaurant (
  restaurant_id    INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  city_id          INT UNSIGNED  NOT NULL,
  restaurant_name  VARCHAR(120)  NOT NULL,
  commission_pct   DECIMAL(5,2)  NOT NULL,
  is_active        BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_restaurant PRIMARY KEY (restaurant_id),
  CONSTRAINT uq_restaurant_city_name UNIQUE (city_id, restaurant_name),
  CONSTRAINT chk_restaurant_commission CHECK (commission_pct BETWEEN 0 AND 100),
  CONSTRAINT fk_restaurant_city FOREIGN KEY (city_id)
    REFERENCES city (city_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- MENU_ITEM  (Step 1; Step 4: OFFERS, RESTAURANT 1 : MENU_ITEM N, total)
CREATE TABLE menu_item (
  menu_item_id   INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  restaurant_id  INT UNSIGNED  NOT NULL,
  item_name      VARCHAR(120)  NOT NULL,
  category       VARCHAR(40)   NOT NULL,
  list_price     DECIMAL(10,2) NOT NULL,
  is_available   BOOLEAN       NOT NULL DEFAULT TRUE,
  CONSTRAINT pk_menu_item PRIMARY KEY (menu_item_id),
  CONSTRAINT uq_menu_item_name UNIQUE (restaurant_id, item_name),
  CONSTRAINT chk_menu_item_price CHECK (list_price > 0),
  CONSTRAINT fk_menu_item_restaurant FOREIGN KEY (restaurant_id)
    REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- DELIVERY_PARTNER  (Step 1; Step 4: BASED_IN, CITY 1 : PARTNER N, total)
CREATE TABLE delivery_partner (
  partner_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  city_id       INT UNSIGNED NOT NULL,
  partner_name  VARCHAR(100) NOT NULL,
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
  CONSTRAINT pk_delivery_partner PRIMARY KEY (partner_id),
  CONSTRAINT fk_delivery_partner_city FOREIGN KEY (city_id)
    REFERENCES city (city_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;


-- =====================================================================
--  C. ORDERS (the centre of the schema)
-- =====================================================================

-- ORDERS  (Step 1; composite Fees -> its 3 leaf columns;
--          Step 4: PLACES and RECEIVES, both total on ORDER -> NOT NULL FKs)
-- Named ORDERS because ORDER is a reserved word in SQL.
-- No city_id: the city is reached through restaurant (avoids a redundant path).
CREATE TABLE orders (
  order_id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  customer_id         INT UNSIGNED    NOT NULL,
  restaurant_id       INT UNSIGNED    NOT NULL,
  order_time          DATETIME        NOT NULL,
  order_status        VARCHAR(20)     NOT NULL DEFAULT 'PLACED',
  delivery_fee        DECIMAL(10,2)   NOT NULL DEFAULT 0,
  platform_fee        DECIMAL(10,2)   NOT NULL DEFAULT 0,
  packaging_fee       DECIMAL(10,2)   NOT NULL DEFAULT 0,
  distance_km         DECIMAL(5,2)    NOT NULL,
  is_peak_period      BOOLEAN         NOT NULL DEFAULT FALSE,
  is_rainy_weather    BOOLEAN         NOT NULL DEFAULT FALSE,
  cancellation_stage  VARCHAR(20)     NULL,
  CONSTRAINT pk_orders PRIMARY KEY (order_id),
  CONSTRAINT chk_orders_status CHECK (order_status IN
    ('PLACED', 'ACCEPTED', 'PREPARING', 'PICKED_UP', 'DELIVERED', 'CANCELLED')),
  CONSTRAINT chk_orders_fees CHECK (delivery_fee >= 0 AND platform_fee >= 0 AND packaging_fee >= 0),
  CONSTRAINT chk_orders_distance CHECK (distance_km BETWEEN 0 AND 50),
  CONSTRAINT chk_orders_cancel_stage CHECK (cancellation_stage IS NULL OR cancellation_stage IN
    ('BEFORE_ACCEPT', 'AFTER_ACCEPT', 'AFTER_PICKUP')),
  -- cross-column rule: a stage exists if and only if the order was cancelled
  CONSTRAINT chk_orders_cancel_consistent CHECK (
    (order_status = 'CANCELLED') = (cancellation_stage IS NOT NULL)),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id)
    REFERENCES customer (customer_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_orders_restaurant FOREIGN KEY (restaurant_id)
    REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  INDEX ix_orders_time (order_time),
  INDEX ix_orders_restaurant_time (restaurant_id, order_time),
  INDEX ix_orders_status (order_status)
) ENGINE = InnoDB;

-- ORDER_ITEM  (Step 5: M:N CONTAINS -> relation with both PKs as the PK,
--              plus the diamond's attributes quantity and unit_price)
-- unit_price is the price AT ORDER TIME, so it is not a copy of list_price.
CREATE TABLE order_item (
  order_id      BIGINT UNSIGNED NOT NULL,
  menu_item_id  INT UNSIGNED    NOT NULL,
  quantity      SMALLINT UNSIGNED NOT NULL,
  unit_price    DECIMAL(10,2)   NOT NULL,
  CONSTRAINT pk_order_item PRIMARY KEY (order_id, menu_item_id),
  CONSTRAINT chk_order_item_qty CHECK (quantity BETWEEN 1 AND 50),
  CONSTRAINT chk_order_item_price CHECK (unit_price >= 0),
  CONSTRAINT fk_order_item_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_order_item_menu FOREIGN KEY (menu_item_id)
    REFERENCES menu_item (menu_item_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- ORDER_COST  (Step 2: WEAK entity, owner ORDER via identifying HAS_COST.
--              No partial key, so PK = owner's PK alone.)
-- ON DELETE CASCADE: a weak entity cannot exist without its owner.
CREATE TABLE order_cost (
  order_id      BIGINT UNSIGNED NOT NULL,
  support_cost  DECIMAL(10,2)   NOT NULL DEFAULT 0,
  CONSTRAINT pk_order_cost PRIMARY KEY (order_id),
  CONSTRAINT chk_order_cost_support CHECK (support_cost >= 0),
  CONSTRAINT fk_order_cost_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE = InnoDB;

-- DELIVERY_TRIP  (Step 1, composites Timeline/Prep_time/Delivery_cost -> leaves;
--   Step 3a: 1:1 FULFILLED_BY, FK on the TOTAL side (trip), NOT NULL + UNIQUE;
--   Step 4: ASSIGNED_TO, PARTNER 1 : TRIP N, total)
CREATE TABLE delivery_trip (
  trip_id                BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  order_id               BIGINT UNSIGNED  NOT NULL,
  partner_id             INT UNSIGNED     NOT NULL,
  assigned_at            DATETIME         NOT NULL,
  picked_up_at           DATETIME         NULL,
  delivered_at           DATETIME         NULL,
  promised_delivery_at   DATETIME         NOT NULL,
  promised_prep_minutes  SMALLINT UNSIGNED NOT NULL,
  actual_prep_minutes    SMALLINT UNSIGNED NULL,
  partner_payout         DECIMAL(10,2)    NOT NULL DEFAULT 0,
  incentive_amount       DECIMAL(10,2)    NOT NULL DEFAULT 0,
  wait_time_pay          DECIMAL(10,2)    NOT NULL DEFAULT 0,
  CONSTRAINT pk_delivery_trip PRIMARY KEY (trip_id),
  CONSTRAINT uq_delivery_trip_order UNIQUE (order_id),          -- keeps it 1:1
  CONSTRAINT chk_trip_pickup_after_assign CHECK (picked_up_at IS NULL OR picked_up_at >= assigned_at),
  CONSTRAINT chk_trip_deliver_after_pickup CHECK (delivered_at IS NULL OR
    (picked_up_at IS NOT NULL AND delivered_at >= picked_up_at)),
  CONSTRAINT chk_trip_promise_after_assign CHECK (promised_delivery_at > assigned_at),
  CONSTRAINT chk_trip_costs CHECK (partner_payout >= 0 AND incentive_amount >= 0 AND wait_time_pay >= 0),
  CONSTRAINT fk_trip_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_trip_partner FOREIGN KEY (partner_id)
    REFERENCES delivery_partner (partner_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;


-- =====================================================================
--  D. MONEY MOVEMENTS ON AN ORDER (all Step 4, ORDER 1 : X N, total on X)
--  ON DELETE RESTRICT: financial history must never vanish silently.
-- =====================================================================

CREATE TABLE payment_transaction (
  payment_id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id            BIGINT UNSIGNED NOT NULL,
  gateway_name        VARCHAR(30)     NOT NULL,
  payment_status      VARCHAR(20)     NOT NULL,
  transaction_amount  DECIMAL(10,2)   NOT NULL,
  gateway_fee         DECIMAL(10,2)   NOT NULL DEFAULT 0,
  transaction_time    DATETIME        NOT NULL,
  CONSTRAINT pk_payment_transaction PRIMARY KEY (payment_id),
  CONSTRAINT chk_payment_status CHECK (payment_status IN ('PENDING', 'SUCCESS', 'FAILED', 'REVERSED')),
  CONSTRAINT chk_payment_gateway CHECK (gateway_name IN ('RAZORPAY', 'PAYU', 'CASHFREE', 'UPI_DIRECT', 'COD')),
  CONSTRAINT chk_payment_amount CHECK (transaction_amount > 0),
  CONSTRAINT chk_payment_fee CHECK (gateway_fee >= 0 AND gateway_fee <= transaction_amount),
  CONSTRAINT fk_payment_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

CREATE TABLE refund (
  refund_id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id          BIGINT UNSIGNED NOT NULL,
  refund_amount     DECIMAL(10,2)   NOT NULL,
  recovered_amount  DECIMAL(10,2)   NOT NULL DEFAULT 0,  -- charged back to restaurant/partner
  responsibility    VARCHAR(20)     NOT NULL,
  refund_reason     VARCHAR(30)     NOT NULL,
  refund_status     VARCHAR(20)     NOT NULL DEFAULT 'REQUESTED',
  created_at        DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_refund PRIMARY KEY (refund_id),
  CONSTRAINT chk_refund_amount CHECK (refund_amount > 0),
  CONSTRAINT chk_refund_recovered_le_refund CHECK (recovered_amount BETWEEN 0 AND refund_amount),
  CONSTRAINT chk_refund_responsibility CHECK (responsibility IN ('RESTAURANT', 'PARTNER', 'PLATFORM', 'CUSTOMER')),
  CONSTRAINT chk_refund_reason CHECK (refund_reason IN
    ('LATE_DELIVERY', 'MISSING_ITEM', 'WRONG_ITEM', 'QUALITY', 'CANCELLED', 'OTHER')),
  CONSTRAINT chk_refund_status CHECK (refund_status IN ('REQUESTED', 'APPROVED', 'REJECTED', 'PROCESSED')),
  CONSTRAINT fk_refund_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  INDEX ix_refund_created (created_at)
) ENGINE = InnoDB;

CREATE TABLE compensation (
  compensation_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id             BIGINT UNSIGNED NOT NULL,
  compensation_amount  DECIMAL(10,2)   NOT NULL,
  reason               VARCHAR(30)     NOT NULL,
  created_at           DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_compensation PRIMARY KEY (compensation_id),
  CONSTRAINT chk_compensation_amount CHECK (compensation_amount > 0),
  CONSTRAINT chk_compensation_reason CHECK (reason IN ('DELAY_VOUCHER', 'GOODWILL', 'SERVICE_FAILURE', 'OTHER')),
  CONSTRAINT fk_compensation_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;


-- =====================================================================
--  E. PROMOTIONS
-- =====================================================================

-- CAMPAIGN  (Step 1; composite Validity -> start_date, end_date)
CREATE TABLE campaign (
  campaign_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  campaign_name  VARCHAR(100) NOT NULL,
  start_date     DATE         NOT NULL,
  end_date       DATE         NOT NULL,
  is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
  CONSTRAINT pk_campaign PRIMARY KEY (campaign_id),
  CONSTRAINT uq_campaign_name UNIQUE (campaign_name),
  CONSTRAINT chk_campaign_dates CHECK (end_date >= start_date)
) ENGINE = InnoDB;

-- COUPON  (Step 1; composite Discount -> 3 leaves;
--          Step 4: ISSUES, CAMPAIGN 1 : COUPON N, partial -> nullable FK)
-- restaurant_share_pct is pinned per funder so ONE formula works for all:
--     platform share = 1 - restaurant_share_pct / 100
--     PLATFORM -> 0, RESTAURANT -> 100, SHARED -> strictly between.
CREATE TABLE coupon (
  coupon_id              INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  campaign_id            INT UNSIGNED  NULL,
  coupon_code            VARCHAR(30)   NOT NULL,
  discount_type          VARCHAR(10)   NOT NULL,
  discount_value         DECIMAL(10,2) NOT NULL,
  max_discount_amount    DECIMAL(10,2) NULL,
  funded_by              VARCHAR(12)   NOT NULL,
  restaurant_share_pct   DECIMAL(5,2)  NOT NULL DEFAULT 0,
  free_delivery          BOOLEAN       NOT NULL DEFAULT FALSE,
  minimum_basket_amount  DECIMAL(10,2) NOT NULL DEFAULT 0,
  CONSTRAINT pk_coupon PRIMARY KEY (coupon_id),
  CONSTRAINT uq_coupon_code UNIQUE (coupon_code),
  CONSTRAINT chk_coupon_type CHECK (discount_type IN ('FLAT', 'PERCENT')),
  CONSTRAINT chk_coupon_value CHECK (discount_value > 0 AND
    (discount_type = 'FLAT' OR discount_value <= 100)),
  CONSTRAINT chk_coupon_cap CHECK (max_discount_amount IS NULL OR max_discount_amount > 0),
  CONSTRAINT chk_coupon_funded_by CHECK (funded_by IN ('PLATFORM', 'RESTAURANT', 'SHARED')),
  CONSTRAINT chk_coupon_share CHECK (
       (funded_by = 'PLATFORM'   AND restaurant_share_pct = 0)
    OR (funded_by = 'RESTAURANT' AND restaurant_share_pct = 100)
    OR (funded_by = 'SHARED'     AND restaurant_share_pct > 0 AND restaurant_share_pct < 100)),
  CONSTRAINT chk_coupon_min_basket CHECK (minimum_basket_amount >= 0),
  CONSTRAINT fk_coupon_campaign FOREIGN KEY (campaign_id)
    REFERENCES campaign (campaign_id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE = InnoDB;

-- DISCOUNT_USAGE  (Step 5: M:N APPLIES -> PK (order_id, coupon_id),
--                  plus diamond attributes discount_amount, used_at)
CREATE TABLE discount_usage (
  order_id         BIGINT UNSIGNED NOT NULL,
  coupon_id        INT UNSIGNED    NOT NULL,
  discount_amount  DECIMAL(10,2)   NOT NULL,
  used_at          DATETIME        NOT NULL,
  CONSTRAINT pk_discount_usage PRIMARY KEY (order_id, coupon_id),
  CONSTRAINT chk_discount_usage_amount CHECK (discount_amount >= 0),
  CONSTRAINT fk_discount_usage_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_discount_usage_coupon FOREIGN KEY (coupon_id)
    REFERENCES coupon (coupon_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;


-- =====================================================================
--  F. LEAK ANALYSIS
-- =====================================================================

CREATE TABLE leak_type (
  leak_type_id  SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  leak_name     VARCHAR(40)  NOT NULL,
  description   VARCHAR(255) NOT NULL,
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
  CONSTRAINT pk_leak_type PRIMARY KEY (leak_type_id),
  CONSTRAINT uq_leak_type_name UNIQUE (leak_name)
) ENGINE = InnoDB;

-- LEAK_RULE  (Step 4: DEFINES, LEAK_TYPE 1 : LEAK_RULE N, total)
-- rule_config is JSON: MySQL itself rejects invalid JSON on insert.
CREATE TABLE leak_rule (
  leak_rule_id     SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  leak_type_id     SMALLINT UNSIGNED NOT NULL,
  rule_name        VARCHAR(80)   NOT NULL,
  threshold_value  DECIMAL(10,2) NOT NULL,
  rule_config      JSON          NULL,
  is_active        BOOLEAN       NOT NULL DEFAULT TRUE,
  updated_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT pk_leak_rule PRIMARY KEY (leak_rule_id),
  CONSTRAINT uq_leak_rule_name UNIQUE (rule_name),
  CONSTRAINT chk_leak_rule_threshold CHECK (threshold_value >= 0),
  CONSTRAINT fk_leak_rule_type FOREIGN KEY (leak_type_id)
    REFERENCES leak_type (leak_type_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- LEAKAGE_RECORD  (Step 1 entity; Step 4 three times:
--   HAS_LEAK   ORDER 1 : N      total   -> order_id NOT NULL
--   CLASSIFIES LEAK_TYPE 1 : N  total   -> leak_type_id NOT NULL
--   DETECTED_BY LEAK_RULE 1 : N partial -> leak_rule_id NULL)
CREATE TABLE leakage_record (
  leakage_record_id  BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  order_id           BIGINT UNSIGNED   NOT NULL,
  leak_type_id       SMALLINT UNSIGNED NOT NULL,
  leak_rule_id       SMALLINT UNSIGNED NULL,
  leak_amount        DECIMAL(10,2)     NOT NULL,   -- EXCESS over benchmark only
  is_primary         BOOLEAN           NOT NULL DEFAULT FALSE,
  detected_at        DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  detection_run_id   VARCHAR(40)       NOT NULL,
  explanation        VARCHAR(255)      NOT NULL,
  CONSTRAINT pk_leakage_record PRIMARY KEY (leakage_record_id),
  CONSTRAINT chk_leakage_amount CHECK (leak_amount > 0),
  -- one row per (order, leak type) in a detection run
  CONSTRAINT uq_leakage_order_type_run UNIQUE (order_id, leak_type_id, detection_run_id),
  CONSTRAINT fk_leakage_order FOREIGN KEY (order_id)
    REFERENCES orders (order_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_leakage_type FOREIGN KEY (leak_type_id)
    REFERENCES leak_type (leak_type_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_leakage_rule FOREIGN KEY (leak_rule_id)
    REFERENCES leak_rule (leak_rule_id) ON DELETE SET NULL ON UPDATE CASCADE,
  INDEX ix_leakage_run (detection_run_id),
  INDEX ix_leakage_type_time (leak_type_id, detected_at)
) ENGINE = InnoDB;

-- "At most ONE primary leak per order per run": a functional index.
-- Non-primary rows give NULL, and UNIQUE allows many NULLs, so only the
-- primary rows (value 1) are forced to be unique per (order, run).
CREATE UNIQUE INDEX uq_leakage_one_primary
  ON leakage_record (order_id, detection_run_id, (IF(is_primary, 1, NULL)));

-- RECOMMENDATION  (Step 1, composite Target -> target_type, target_id;
--   Step 4: ADDRESSES, LEAK_TYPE 1 : N partial -> nullable FK)
-- target_id is POLYMORPHIC (points to a restaurant, a city, a coupon ...),
-- so it cannot be a FK. A trigger validates it against target_type later.
CREATE TABLE recommendation (
  recommendation_id    BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  leak_type_id         SMALLINT UNSIGNED NULL,
  target_type          VARCHAR(20)       NOT NULL,
  target_id            INT UNSIGNED      NULL,
  recommendation_text  VARCHAR(500)      NOT NULL,
  estimated_saving     DECIMAL(12,2)     NOT NULL DEFAULT 0,
  demand_risk          VARCHAR(10)       NOT NULL,
  priority_score       DECIMAL(5,2)      NOT NULL,
  created_at           DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status               VARCHAR(15)       NOT NULL DEFAULT 'NEW',
  CONSTRAINT pk_recommendation PRIMARY KEY (recommendation_id),
  CONSTRAINT chk_reco_target_type CHECK (target_type IN
    ('GLOBAL', 'REGION', 'CITY', 'RESTAURANT', 'COUPON', 'CAMPAIGN', 'DELIVERY_PARTNER')),
  CONSTRAINT chk_reco_target_id CHECK ((target_type = 'GLOBAL') = (target_id IS NULL)),
  CONSTRAINT chk_reco_saving CHECK (estimated_saving >= 0),
  CONSTRAINT chk_reco_risk CHECK (demand_risk IN ('LOW', 'MEDIUM', 'HIGH')),
  CONSTRAINT chk_reco_priority CHECK (priority_score BETWEEN 0 AND 100),
  CONSTRAINT chk_reco_status CHECK (status IN ('NEW', 'ACCEPTED', 'REJECTED', 'IMPLEMENTED')),
  CONSTRAINT fk_reco_leak_type FOREIGN KEY (leak_type_id)
    REFERENCES leak_type (leak_type_id) ON DELETE SET NULL ON UPDATE CASCADE,
  INDEX ix_reco_status_priority (status, priority_score),
  INDEX ix_reco_target (target_type, target_id)
) ENGINE = InnoDB;


-- =====================================================================
--  G. APPLICATION SECURITY (app-level RBAC; DB-level roles are in 02_roles.sql)
-- =====================================================================

CREATE TABLE app_role (
  role_id      TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
  role_name    VARCHAR(20)  NOT NULL,
  description  VARCHAR(255) NOT NULL,
  CONSTRAINT pk_app_role PRIMARY KEY (role_id),
  CONSTRAINT uq_app_role_name UNIQUE (role_name),
  CONSTRAINT chk_app_role_name CHECK (role_name IN ('ADMIN', 'ANALYST', 'VIEWER'))
) ENGINE = InnoDB;

-- APP_USER  (Step 4: HAS_ROLE, APP_ROLE 1 : APP_USER N, total)
CREATE TABLE app_user (
  user_id        INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  role_id        TINYINT UNSIGNED NOT NULL,
  full_name      VARCHAR(100)     NOT NULL,
  email          VARCHAR(120)     NOT NULL,
  password_hash  VARCHAR(255)     NOT NULL,   -- bcrypt hash, never the password
  is_active      BOOLEAN          NOT NULL DEFAULT TRUE,
  created_at     DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_app_user PRIMARY KEY (user_id),
  CONSTRAINT uq_app_user_email UNIQUE (email),
  CONSTRAINT chk_app_user_hash CHECK (CHAR_LENGTH(password_hash) >= 50),
  CONSTRAINT fk_app_user_role FOREIGN KEY (role_id)
    REFERENCES app_role (role_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- AUDIT_LOG  (Step 4: PERFORMS, APP_USER 1 : AUDIT_LOG N, partial ->
--   nullable actor: triggers and system jobs write rows with no user)
CREATE TABLE audit_log (
  audit_log_id   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  actor_user_id  INT UNSIGNED    NULL,
  entity_name    VARCHAR(40)     NOT NULL,
  entity_id      VARCHAR(40)     NOT NULL,
  action_name    VARCHAR(20)     NOT NULL,
  old_values     JSON            NULL,
  new_values     JSON            NULL,
  created_at     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_audit_log PRIMARY KEY (audit_log_id),
  CONSTRAINT chk_audit_action CHECK (action_name IN ('INSERT', 'UPDATE', 'DELETE', 'LOGIN', 'RUN')),
  CONSTRAINT fk_audit_actor FOREIGN KEY (actor_user_id)
    REFERENCES app_user (user_id) ON DELETE SET NULL ON UPDATE CASCADE,
  INDEX ix_audit_entity (entity_name, entity_id),
  INDEX ix_audit_created (created_at)
) ENGINE = InnoDB;

-- Quick self-check after running:  should list 23 tables.
-- SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'quickbite';
