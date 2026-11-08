// Step 8 tests: the running web app over HTTP (start it first: npm run build && npm start).
//   cd web && npm run test:step8            # everything except a real detection run
//   cd web && npm run test:step8 -- --run   # also presses "Run detection" once (adds a run, ~5 s)
// Test rows (one recommendation, notes tagged "test") are removed at the end.
import assert from 'node:assert/strict';
import { query, closeAll } from '../lib/mysql.js';

const BASE = process.env.WEB_URL ?? 'http://localhost:3000';
const LOGINS = {
  ADMIN: ['admin@quickbite.dev', 'Admin@App123'],
  ANALYST: ['analyst@quickbite.dev', 'Analyst@App123'],
  VIEWER: ['viewer@quickbite.dev', 'Viewer@App123'],
};
let passed = 0;
async function check(name, fn) {
  try { await fn(); passed++; console.log(`PASS  ${name}`); }
  catch (err) { console.log(`FAIL  ${name}\n      ${err.message}`); process.exitCode = 1; }
}
async function http(path, { cookie, method = 'GET', json, form, redirect = 'manual' } = {}) {
  const headers = {};
  if (cookie) headers.cookie = cookie;
  let body;
  if (json !== undefined) { headers['content-type'] = 'application/json'; body = JSON.stringify(json); }
  if (form) { headers['content-type'] = 'application/x-www-form-urlencoded'; body = new URLSearchParams(form).toString(); }
  const res = await fetch(BASE + path, { method, headers, body, redirect });
  const text = await res.text();
  let data = null;
  try { data = JSON.parse(text); } catch { /* HTML page */ }
  return { status: res.status, headers: res.headers, text, data };
}
const sessionFrom = (res) => (res.headers.get('set-cookie') ?? '').match(/qb_session=[^;]*/)?.[0];

const cookies = {};
const ids = {};

console.log('\n-- Login and sessions');
await check('wrong password and unknown email -> 401', async () => {
  assert.equal((await http('/api/auth/login', { method: 'POST', json: { email: LOGINS.ADMIN[0], password: 'nope' } })).status, 401);
  assert.equal((await http('/api/auth/login', { method: 'POST', json: { email: 'nobody@x.dev', password: 'x' } })).status, 401);
});
for (const role of Object.keys(LOGINS)) {
  await check(`${role} logs in; cookie is httpOnly and signed; /api/me says ${role}`, async () => {
    const res = await http('/api/auth/login', { method: 'POST', json: { email: LOGINS[role][0], password: LOGINS[role][1] } });
    assert.equal(res.status, 200);
    assert.match(res.headers.get('set-cookie'), /HttpOnly/i);
    cookies[role] = sessionFrom(res);
    assert.match(cookies[role], /^qb_session=[\w-]+\.[\w-]+$/);
    const me = await http('/api/me', { cookie: cookies[role] });
    assert.equal(me.data.user.role, role);
    ids[role] = me.data.user.id;
  });
}
await check('HTML form login redirects (303) to / with a session cookie', async () => {
  const res = await http('/api/auth/login', { method: 'POST', form: { email: LOGINS.VIEWER[0], password: LOGINS.VIEWER[1] } });
  assert.equal(res.status, 303);
  assert.equal(new URL(res.headers.get('location'), BASE).pathname, '/');
  assert.ok(sessionFrom(res));
});
await check('a tampered cookie (role changed to ADMIN) is rejected -> 401', async () => {
  const [body, sig] = cookies.VIEWER.slice('qb_session='.length).split('.');
  const p = JSON.parse(Buffer.from(body, 'base64url').toString());
  const forged = Buffer.from(JSON.stringify({ ...p, role: 'ADMIN' })).toString('base64url');
  assert.equal((await http('/api/me', { cookie: `qb_session=${forged}.${sig}` })).status, 401);
  assert.equal((await http('/api/admin/run', { method: 'POST', cookie: `qb_session=${forged}.${sig}` })).status, 401);
});
await check('no session: API -> 401, page -> redirect to /login', async () => {
  assert.equal((await http('/api/kpi')).status, 401);
  const page = await http('/notes');
  assert.equal(page.status, 307);
  assert.equal(new URL(page.headers.get('location'), BASE).pathname, '/login');
});
await check('logout clears the cookie (Max-Age=0)', async () => {
  const res = await http('/api/auth/logout', { method: 'POST', json: {}, cookie: cookies.VIEWER });
  assert.equal(res.status, 200);
  assert.match(res.headers.get('set-cookie'), /qb_session=;.*Max-Age=0/i);
});
await check('every login attempt is in audit_log (LOGIN, success true/false)', async () => {
  const rows = await query('ADMIN',
    `SELECT JSON_EXTRACT(new_values, '$.success') AS ok, COUNT(*) AS n FROM audit_log
      WHERE action_name = 'LOGIN' AND created_at >= NOW() - INTERVAL 5 MINUTE GROUP BY ok`);
  assert.ok(rows.find((r) => Number(r.ok) === 1)?.n >= 4);
  assert.ok(rows.find((r) => Number(r.ok) === 0)?.n >= 2);
});

console.log('\n-- Pages for every role');
const PAGES = { '/': 'Monthly KPIs', '/leaks': 'Leak types: Pareto', '/recommendations': 'Ranked by priority', '/notes': 'Leak notes' };
for (const role of Object.keys(LOGINS)) {
  await check(`${role}: Overview, Leaks, Recommendations, Leak notes render (200)`, async () => {
    for (const [path, text] of Object.entries(PAGES)) {
      const res = await http(path, { cookie: cookies[role] });
      assert.equal(res.status, 200, path);
      assert.ok(res.text.includes(text), `${path} lacks "${text}"`);
      assert.ok(res.text.includes(`>${role}<`), `${path} does not show the role`);
    }
  });
  await check(`${role}: Run detection page ${role === 'ADMIN' ? 'shows the button' : 'says Access denied'}; nav link ${role === 'ADMIN' ? 'shown' : 'hidden'}`, async () => {
    const res = await http('/admin/run', { cookie: cookies[role] });
    assert.equal(res.status, 200);
    if (role === 'ADMIN') assert.ok(res.text.includes('Run detection now'));
    else { assert.ok(res.text.includes('Access denied')); assert.ok(!res.text.includes('Run detection now')); }
    const home = await http('/', { cookie: cookies[role] });
    assert.equal(home.text.includes('href="/admin/run"'), role === 'ADMIN');
  });
}

console.log('\n-- Dashboard API (MySQL views through the role pool, Redis cache)');
await check('/api/kpi: 12 months; a repeat call is served from Redis', async () => {
  await http('/api/kpi', { cookie: cookies.VIEWER });
  const res = await http('/api/kpi', { cookie: cookies.VIEWER });
  assert.equal(res.data.monthly.data.length, 12);
  assert.equal(res.data.monthly.source, 'redis');
  assert.equal(res.data.cities.data.length, 9);
});
await check('/api/leaks: Pareto of 6 types (3 in the 80%), leaderboard top = restaurant 121', async () => {
  const res = await http('/api/leaks', { cookie: cookies.ANALYST });
  assert.equal(res.data.pareto.data.length, 6);
  assert.equal(res.data.pareto.data.filter((p) => p.in_top_80).length, 3);
  assert.equal(res.data.leaderboard.data[0].id, 121);
});

console.log('\n-- Recommendations: RBAC enforced by MySQL itself');
const ins = await query('ADMIN',
  `INSERT INTO recommendation (leak_type_id, target_type, target_id, recommendation_text, estimated_saving, demand_risk, priority_score)
   VALUES (5, 'GLOBAL', NULL, 'test recommendation (step 8 test)', 1, 'LOW', 0)`);
const recoId = ins.insertId;
await check('viewer changes status -> 403 "Access denied by MySQL: UPDATE command denied"', async () => {
  const res = await http(`/api/recommendations/${recoId}`, { method: 'PATCH', cookie: cookies.VIEWER, json: { status: 'ACCEPTED' } });
  assert.equal(res.status, 403);
  assert.match(res.data.error, /Access denied by MySQL: UPDATE command denied to user 'qb_viewer_user'/);
});
await check('analyst: NEW -> ACCEPTED works (column-level UPDATE(status) grant)', async () => {
  const res = await http(`/api/recommendations/${recoId}`, { method: 'PATCH', cookie: cookies.ANALYST, json: { status: 'ACCEPTED' } });
  assert.equal(res.status, 200);
  assert.equal(res.data.recommendation.status, 'ACCEPTED');
});
await check('analyst: ACCEPTED -> NEW refused by the trigger -> 400', async () => {
  const res = await http(`/api/recommendations/${recoId}`, { method: 'PATCH', cookie: cookies.ANALYST, json: { status: 'NEW' } });
  assert.equal(res.status, 400);
  assert.match(res.data.error, /cannot change from ACCEPTED to NEW/);
});
await check('admin: ACCEPTED -> IMPLEMENTED; audit_log names analyst then admin', async () => {
  const res = await http(`/api/recommendations/${recoId}`, { method: 'PATCH', cookie: cookies.ADMIN, json: { status: 'IMPLEMENTED' } });
  assert.equal(res.status, 200);
  const audit = await query('ADMIN',
    `SELECT actor_user_id AS actor, new_values->>'$.status' AS status FROM audit_log
      WHERE entity_name = 'recommendation' AND entity_id = ? ORDER BY audit_log_id`, [String(recoId)]);
  assert.deepEqual(audit.map((a) => [a.actor, a.status]), [[ids.ANALYST, 'ACCEPTED'], [ids.ADMIN, 'IMPLEMENTED']]);
});
await check('unknown recommendation -> 404; bad status -> 400', async () => {
  assert.equal((await http('/api/recommendations/999999999', { method: 'PATCH', cookie: cookies.ADMIN, json: { status: 'REJECTED' } })).status, 404);
  assert.equal((await http(`/api/recommendations/${recoId}`, { method: 'PATCH', cookie: cookies.ADMIN, json: { status: 'DONE' } })).status, 400);
});

console.log('\n-- Leak notes API (MongoDB CRUD)');
const [leak] = await query('ADMIN', `SELECT leakage_record_id AS id, order_id FROM leakage_record
                                     WHERE leak_type_id = 4 ORDER BY leakage_record_id DESC LIMIT 1`);
let noteId;
await check('viewer: list works; create -> 403 with a clear message', async () => {
  assert.equal((await http('/api/notes', { cookie: cookies.VIEWER })).status, 200);
  const res = await http('/api/notes', { method: 'POST', cookie: cookies.VIEWER,
    json: { leak_ref: { kind: 'leakage_record', id: leak.id }, title: 'viewer try', body: 'x' } });
  assert.equal(res.status, 403);
  assert.match(res.data.error, /viewers can read leak notes but not change them/);
});
await check('analyst: create (201) -> leak_type/order copied from MySQL', async () => {
  const res = await http('/api/notes', { method: 'POST', cookie: cookies.ANALYST,
    json: { leak_ref: { kind: 'leakage_record', id: leak.id }, title: 'Step 8 test note', body: 'refund not recovered', tags: ['test', 'refund'] } });
  assert.equal(res.status, 201);
  assert.equal(res.data.note.leak_type, 'UNRECOVERED_REFUND');
  assert.equal(res.data.note.order_id, leak.order_id);
  noteId = res.data.note._id;
});
await check('read: filter by leak type, order, tag; get one by id', async () => {
  const byType = await http('/api/notes?leakType=UNRECOVERED_REFUND&tag=test', { cookie: cookies.VIEWER });
  assert.ok(byType.data.notes.some((n) => n._id === noteId));
  const byOrder = await http(`/api/notes?orderId=${leak.order_id}`, { cookie: cookies.VIEWER });
  assert.ok(byOrder.data.notes.some((n) => n._id === noteId));
  assert.equal((await http(`/api/notes/${noteId}`, { cookie: cookies.VIEWER })).data.note.title, 'Step 8 test note');
  const page = await http('/notes?tag=test', { cookie: cookies.VIEWER });
  assert.ok(page.text.includes('Step 8 test note'));
});
await check('update: analyst 200; viewer 403', async () => {
  const ok = await http(`/api/notes/${noteId}`, { method: 'PATCH', cookie: cookies.ANALYST, json: { status: 'RESOLVED' } });
  assert.equal(ok.data.note.status, 'RESOLVED');
  assert.equal((await http(`/api/notes/${noteId}`, { method: 'PATCH', cookie: cookies.VIEWER, json: { status: 'OPEN' } })).status, 403);
});
await check('delete: viewer 403; analyst 200; then 404', async () => {
  assert.equal((await http(`/api/notes/${noteId}`, { method: 'DELETE', cookie: cookies.VIEWER })).status, 403);
  assert.equal((await http(`/api/notes/${noteId}`, { method: 'DELETE', cookie: cookies.ANALYST })).status, 200);
  assert.equal((await http(`/api/notes/${noteId}`, { cookie: cookies.ANALYST })).status, 404);
});

console.log('\n-- Run detection (admin only)');
await check('viewer and analyst -> 403 "Access denied: ADMIN only"', async () => {
  for (const role of ['VIEWER', 'ANALYST']) {
    const res = await http('/api/admin/run', { method: 'POST', cookie: cookies[role] });
    assert.equal(res.status, 403);
    assert.match(res.data.error, /Access denied: ADMIN only/);
  }
});
if (process.argv.includes('--run')) {
  await check('admin run: new run id, leaks + recommendations written, cache cleared, dashboards re-read MySQL', async () => {
    const before = (await http('/api/leaks', { cookie: cookies.ADMIN })).data.pareto.key;
    const res = await http('/api/admin/run', { method: 'POST', cookie: cookies.ADMIN });
    assert.equal(res.status, 200, res.text);
    const r = res.data.run;
    assert.match(r.run_id, /^run-\d{8}-\d{6}-\d{6}$/);
    assert.ok(r.leaks > 40000 && r.recommendations > 40, JSON.stringify(r));
    assert.ok(r.cacheKeysCleared >= 1);
    const after = (await http('/api/leaks', { cookie: cookies.ADMIN })).data.pareto;
    assert.equal(after.source, 'mysql');
    assert.notEqual(after.key, before);
    assert.ok(after.key.includes(r.run_id));
    const [audit] = await query('ADMIN', `SELECT actor_user_id AS actor FROM audit_log
      WHERE action_name = 'RUN' AND entity_id = ? AND entity_name = 'leakage_record'`, [r.run_id]);
    assert.equal(audit.actor, ids.ADMIN);
    console.log(`      ${r.run_id}: ${r.leaks} leaks, ${r.recommendations} recommendations, ${r.seconds}s`);
  });
} else {
  console.log('SKIP  admin run (add -- --run to press the button for real)');
}

await query('ADMIN', 'DELETE FROM recommendation WHERE recommendation_id = ?', [recoId]);
await query('ADMIN', `DELETE FROM audit_log WHERE entity_name = 'recommendation' AND entity_id = ?`, [String(recoId)]);
console.log(`\n${passed} passed${process.exitCode ? ', SOME FAILED' : ', all passed'}`);
await closeAll();
