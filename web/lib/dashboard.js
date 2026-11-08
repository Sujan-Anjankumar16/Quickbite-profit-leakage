// Dashboard data. Every function takes the caller's role, so the MySQL account
// of that role runs the query, and results are cached per role in Redis.
import { query } from './mysql.js';
import { cached, cachedLeaderboard, latestRunId } from './cache.js';

export function monthlyKpi(role) {
  return cached(role, 'kpi:monthly', () => query(role,
    `SELECT order_month, closed_orders, delivered_orders, cancel_rate_pct, gmv, revenue,
            platform_discount, delivery_cost, refund_loss, contribution,
            contribution_per_delivered, loss_making_orders, total_loss
       FROM v_monthly_kpi ORDER BY order_month`));
}

export function cityScorecard(role) {
  return cached(role, 'kpi:cities', () => query(role,
    `SELECT city_name, state_name, zone_name, closed_orders, revenue, contribution,
            contribution_per_delivered, loss_making_pct
       FROM v_city_scorecard ORDER BY contribution_per_delivered`));
}

// Pareto of leak types in the latest run (primary leaks: every order counted once).
export function leakPareto(role) {
  return cached(role, 'leaks:pareto', async () => {
    const run = await latestRunId(role);
    return query(role,
      `WITH by_type AS (
         SELECT lt.leak_name, COUNT(*) AS orders, SUM(lr.leak_amount) AS leak
           FROM leakage_record lr JOIN leak_type lt ON lt.leak_type_id = lr.leak_type_id
          WHERE lr.detection_run_id = ? AND lr.is_primary
          GROUP BY lt.leak_name)
       SELECT leak_name, orders, leak,
              ROUND(100 * leak / SUM(leak) OVER (), 1)                                AS pct,
              ROUND(100 * SUM(leak) OVER (ORDER BY leak DESC) / SUM(leak) OVER (), 1) AS cum_pct,
              100 * (SUM(leak) OVER (ORDER BY leak DESC) - leak) / SUM(leak) OVER () < 80 AS in_top_80
         FROM by_type ORDER BY leak DESC`, [run]);
  });
}

// Leaderboard: restaurants with the largest primary leak in the latest run.
export function restaurantLeakBoard(role, limit = 10) {
  return cachedLeaderboard(role, 'board:restaurant_leak', limit, async () => {
    const run = await latestRunId(role);
    return query(role,
      `SELECT r.restaurant_id AS id, r.restaurant_name AS name, c.city_name AS city,
              SUM(lr.leak_amount) AS score
         FROM leakage_record lr
         JOIN orders o     ON o.order_id = lr.order_id
         JOIN restaurant r ON r.restaurant_id = o.restaurant_id
         JOIN city c       ON c.city_id = r.city_id
        WHERE lr.detection_run_id = ? AND lr.is_primary
        GROUP BY r.restaurant_id, r.restaurant_name, c.city_name`, [run]);
  });
}
