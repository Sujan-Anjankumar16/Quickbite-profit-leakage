-- =====================================================================
--  QuickBite  -  02_roles.sql
--  Role-based access control INSIDE the database
--  (rubric: "minimum two roles and role-based access control in database")
--
--  Two layers work together:
--    1. app_role / app_user tables  -> who may log in to the web app, and as what
--    2. MySQL roles (this file)     -> what each kind of user may do to the data
--  The Next.js API keeps one connection pool per MySQL login below and picks
--  the pool from the logged-in user's app_role. So even a bug in the API
--  cannot let a VIEWER update data: MySQL itself refuses.
--
--  Passwords here are DEVELOPMENT ONLY. Change them before any real deployment.
-- =====================================================================
USE quickbite;

-- ---------------------------------------------------------------------
-- 1. Roles (a role is a named bundle of privileges)
-- ---------------------------------------------------------------------
DROP ROLE IF EXISTS qb_admin, qb_analyst, qb_viewer;
CREATE ROLE qb_admin, qb_analyst, qb_viewer;

-- ---------------------------------------------------------------------
-- 2. qb_admin: full control of the quickbite schema (but cannot grant to others)
-- ---------------------------------------------------------------------
GRANT ALL PRIVILEGES ON quickbite.* TO qb_admin;

-- ---------------------------------------------------------------------
-- 3. qb_analyst: reads everything needed for analysis, tunes leak rules,
--    and moves recommendations through their workflow.
--    Grants are per table, because a schema-wide SELECT would also expose
--    app_user.password_hash.
-- ---------------------------------------------------------------------
GRANT SELECT ON quickbite.region              TO qb_analyst;
GRANT SELECT ON quickbite.city                TO qb_analyst;
GRANT SELECT ON quickbite.customer            TO qb_analyst;
GRANT SELECT ON quickbite.restaurant          TO qb_analyst;
GRANT SELECT ON quickbite.menu_item           TO qb_analyst;
GRANT SELECT ON quickbite.delivery_partner    TO qb_analyst;
GRANT SELECT ON quickbite.orders              TO qb_analyst;
GRANT SELECT ON quickbite.order_item          TO qb_analyst;
GRANT SELECT ON quickbite.order_cost          TO qb_analyst;
GRANT SELECT ON quickbite.delivery_trip       TO qb_analyst;
GRANT SELECT ON quickbite.payment_transaction TO qb_analyst;
GRANT SELECT ON quickbite.refund              TO qb_analyst;
GRANT SELECT ON quickbite.compensation        TO qb_analyst;
GRANT SELECT ON quickbite.campaign            TO qb_analyst;
GRANT SELECT ON quickbite.coupon              TO qb_analyst;
GRANT SELECT ON quickbite.discount_usage      TO qb_analyst;
GRANT SELECT ON quickbite.leak_type           TO qb_analyst;
GRANT SELECT ON quickbite.leakage_record      TO qb_analyst;
GRANT SELECT ON quickbite.app_role            TO qb_analyst;
GRANT SELECT ON quickbite.audit_log           TO qb_analyst;

-- Column-level privilege: analysts see users, never their password hashes.
GRANT SELECT (user_id, role_id, full_name, email, is_active, created_at)
  ON quickbite.app_user TO qb_analyst;

-- Analysts own the leak rules (thresholds, JSON config).
GRANT SELECT, INSERT, UPDATE ON quickbite.leak_rule TO qb_analyst;

-- Column-level UPDATE: analysts may change ONLY the status of a recommendation
-- (NEW -> ACCEPTED / REJECTED / IMPLEMENTED), not its numbers or text.
GRANT SELECT ON quickbite.recommendation TO qb_analyst;
GRANT UPDATE (status) ON quickbite.recommendation TO qb_analyst;

-- GRANT then REVOKE: a policy decision recorded in the script.
-- Leak types were briefly editable by analysts; the team decided the list of
-- leak categories is admin-managed, so the UPDATE right is taken back.
GRANT UPDATE ON quickbite.leak_type TO qb_analyst;
REVOKE UPDATE ON quickbite.leak_type FROM qb_analyst;

-- (EXECUTE on sp_detect_leaks / sp_generate_recommendations and SELECT on
--  the views are added in the files that create them.)

-- ---------------------------------------------------------------------
-- 4. qb_viewer: read-only dashboards, no personal data, no money details
-- ---------------------------------------------------------------------
GRANT SELECT ON quickbite.region           TO qb_viewer;
GRANT SELECT ON quickbite.city             TO qb_viewer;
GRANT SELECT ON quickbite.restaurant       TO qb_viewer;
GRANT SELECT ON quickbite.menu_item        TO qb_viewer;
GRANT SELECT ON quickbite.orders           TO qb_viewer;
GRANT SELECT ON quickbite.order_item       TO qb_viewer;
GRANT SELECT ON quickbite.campaign         TO qb_viewer;
GRANT SELECT ON quickbite.coupon           TO qb_viewer;
GRANT SELECT ON quickbite.leak_type        TO qb_viewer;
GRANT SELECT ON quickbite.leakage_record   TO qb_viewer;
GRANT SELECT ON quickbite.recommendation   TO qb_viewer;
-- Column-level: a viewer can count customers and follow referrals,
-- but cannot read names, emails or phone numbers.
GRANT SELECT (customer_id, referred_by_customer_id, created_at)
  ON quickbite.customer TO qb_viewer;

-- ---------------------------------------------------------------------
-- 5. Login accounts, one per role. The API connects with these.
-- ---------------------------------------------------------------------
DROP USER IF EXISTS 'qb_admin_user'@'%', 'qb_analyst_user'@'%', 'qb_viewer_user'@'%';
CREATE USER 'qb_admin_user'@'%'   IDENTIFIED BY 'Admin@Dev123';
CREATE USER 'qb_analyst_user'@'%' IDENTIFIED BY 'Analyst@Dev123';
CREATE USER 'qb_viewer_user'@'%'  IDENTIFIED BY 'Viewer@Dev123';

GRANT qb_admin   TO 'qb_admin_user'@'%';
GRANT qb_analyst TO 'qb_analyst_user'@'%';
GRANT qb_viewer  TO 'qb_viewer_user'@'%';

-- A granted role is inactive until activated; make it active on every login.
SET DEFAULT ROLE ALL TO 'qb_admin_user'@'%', 'qb_analyst_user'@'%', 'qb_viewer_user'@'%';

-- ---------------------------------------------------------------------
-- 6. The matching application roles (app layer). Users are created later
--    by the seed script, because passwords must be bcrypt-hashed first.
-- ---------------------------------------------------------------------
INSERT INTO app_role (role_name, description) VALUES
  ('ADMIN',   'Full access: users, leak types, all data. Uses MySQL role qb_admin.'),
  ('ANALYST', 'Runs detection, tunes leak rules, reviews recommendations. Uses qb_analyst.'),
  ('VIEWER',  'Read-only dashboards without personal or payment data. Uses qb_viewer.')
AS new_row
ON DUPLICATE KEY UPDATE description = new_row.description;   -- safe to re-run

-- ---------------------------------------------------------------------
-- 7. How to check it (run as root):
--    SHOW GRANTS FOR qb_analyst;
--    SHOW GRANTS FOR 'qb_viewer_user'@'%' USING qb_viewer;
--  and as qb_viewer_user, this must fail with "UPDATE command denied":
--    UPDATE quickbite.recommendation SET status = 'ACCEPTED' WHERE recommendation_id = 1;
--  and this must fail with "SELECT command denied ... for column 'email'":
--    SELECT email FROM quickbite.customer LIMIT 1;
-- ---------------------------------------------------------------------
