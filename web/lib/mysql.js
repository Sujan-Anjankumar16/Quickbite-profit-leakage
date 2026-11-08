// One MySQL connection pool PER ROLE. The logged-in user's app_role picks the
// pool, so every query runs as qb_admin_user / qb_analyst_user / qb_viewer_user
// and MySQL itself enforces what that role may do (02_roles.sql, 04, 06).
import mysql from 'mysql2/promise';

const ACCOUNTS = {
  ADMIN:   ['DB_ADMIN_USER', 'DB_ADMIN_PASSWORD'],
  ANALYST: ['DB_ANALYST_USER', 'DB_ANALYST_PASSWORD'],
  VIEWER:  ['DB_VIEWER_USER', 'DB_VIEWER_PASSWORD'],
};

// globalThis keeps one set of pools across Next.js hot reloads.
const pools = (globalThis.__qbPools ??= {});

export function pool(role) {
  const account = ACCOUNTS[role];
  if (!account) throw new Error(`Unknown role ${role}`);
  if (!pools[role]) {
    pools[role] = mysql.createPool({
      host: process.env.DB_HOST,
      port: Number(process.env.DB_PORT),
      database: process.env.DB_NAME,
      user: process.env[account[0]],
      password: process.env[account[1]],
      connectionLimit: 5,
      decimalNumbers: true,     // DECIMAL -> JS number (display only; money maths stays in SQL)
      dateStrings: true,        // DATETIME as 'YYYY-MM-DD HH:MM:SS', no timezone shifts
    });
  }
  return pools[role];
}

export async function query(role, sql, params = []) {
  const [rows] = await pool(role).query(sql, params);
  return rows;
}

// Runs fn(conn) on one connection with @app_user_id set, so the audit
// triggers (06_procedures.sql) record who made the change.
export async function withUser(role, userId, fn) {
  const conn = await pool(role).getConnection();
  try {
    await conn.query('SET @app_user_id = ?', [userId ?? null]);
    return await fn(conn);
  } finally {
    await conn.query('SET @app_user_id = NULL').catch(() => {});
    conn.release();
  }
}

export async function closeAll() {
  await Promise.all(Object.keys(pools).map(async (r) => { await pools[r].end(); delete pools[r]; }));
}
