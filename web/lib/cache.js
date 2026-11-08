// Redis cache for dashboard KPIs (JSON strings) and leaderboards (sorted sets).
//
// Keys:  qb:<latest detection run id>:<ROLE>:<name>      TTL = CACHE_TTL seconds
//  * The RUN ID in the key means a new detection run automatically misses the
//    old entries, even if the run was started from the MySQL command line.
//    The run endpoint also calls invalidateAll() to delete them at once.
//  * The ROLE in the key keeps each role's results apart, so a viewer can never
//    be served data that was fetched with the analyst's MySQL account.
//  * The TTL bounds staleness for data that changes without a run.
import { createClient } from 'redis';
import { query } from './mysql.js';

export const CACHE_TTL = 600;
const state = (globalThis.__qbRedis ??= { client: null, ready: null });

export async function redis() {
  if (!state.ready) {
    state.client = createClient({ url: process.env.REDIS_URL });
    state.client.on('error', (e) => console.error('redis', e.message));
    state.ready = state.client.connect();
  }
  await state.ready;
  return state.client;
}

export async function closeRedis() {
  if (state.client) await state.client.quit();
  state.client = null;
  state.ready = null;
}

// Newest run = the run of the highest leakage_record_id (primary-key lookup).
export async function latestRunId(role) {
  const rows = await query(role,
    'SELECT detection_run_id FROM leakage_record ORDER BY leakage_record_id DESC LIMIT 1');
  return rows[0]?.detection_run_id ?? 'none';
}

export const cacheKey = (runId, role, name) => `qb:${runId}:${role}:${name}`;

// Cache-aside: return the cached JSON, or run loader() against MySQL and store it.
export async function cached(role, name, loader) {
  const r = await redis();
  const key = cacheKey(await latestRunId(role), role, name);
  const hit = await r.get(key);
  if (hit) return { data: JSON.parse(hit), source: 'redis', key, ttl: await r.ttl(key) };
  const data = await loader();
  await r.set(key, JSON.stringify(data), { EX: CACHE_TTL });
  return { data, source: 'mysql', key, ttl: CACHE_TTL };
}

// Leaderboard in a Redis SORTED SET: member = "id|name|city", score = leak amount.
// ZRANGE ... REV returns it already ranked, highest leak first.
export async function cachedLeaderboard(role, name, limit, loader) {
  const r = await redis();
  const key = cacheKey(await latestRunId(role), role, name);
  let source = 'redis';
  if (!(await r.exists(key))) {
    source = 'mysql';
    const rows = await loader();               // [{ id, name, city, score }]
    if (rows.length) {
      await r.zAdd(key, rows.map((x) => ({ score: Number(x.score), value: `${x.id}|${x.name}|${x.city}` })));
      await r.expire(key, CACHE_TTL);
    }
  }
  const entries = await r.zRangeWithScores(key, 0, limit - 1, { REV: true });
  return {
    source, key, ttl: await r.ttl(key),
    data: entries.map((e, i) => {
      const [id, label, city] = e.value.split('|');
      return { rank: i + 1, id: Number(id), name: label, city, score: e.score };
    }),
  };
}

// Delete every QuickBite key (SCAN, not KEYS, so Redis is never blocked).
export async function invalidateAll() {
  const r = await redis();
  let removed = 0;
  for await (const keys of r.scanIterator({ MATCH: 'qb:*', COUNT: 200 })) {
    const batch = Array.isArray(keys) ? keys : [keys];
    if (batch.length) removed += await r.del(batch);
  }
  return removed;
}
