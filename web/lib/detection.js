// "Run detection" (admin only in the app): sp_detect_leaks over the whole data
// window, then sp_generate_recommendations for that run, then clear the Redis
// cache so every dashboard shows the new run. Runs as qb_admin_user with
// @app_user_id set, so the RUN rows in audit_log name the admin.
import { query, withUser } from './mysql.js';
import { invalidateAll } from './cache.js';

export async function runDetection(user) {
  const started = Date.now();
  const [range] = await query('ADMIN',
    `SELECT DATE(MIN(order_time)) AS date_from,
            DATE(MAX(order_time)) + INTERVAL 1 DAY AS date_to FROM orders`);
  const result = await withUser('ADMIN', user.id, async (conn) => {
    await conn.query('CALL sp_detect_leaks(?, ?, @run, @leaks)', [range.date_from, range.date_to]);
    await conn.query('CALL sp_generate_recommendations(@run, @recos)');
    const [[row]] = await conn.query('SELECT @run AS run_id, @leaks AS leaks, @recos AS recommendations');
    return row;
  });
  const cacheKeysCleared = await invalidateAll();
  return { ...result, ...range, cacheKeysCleared, seconds: (Date.now() - started) / 1000 };
}
