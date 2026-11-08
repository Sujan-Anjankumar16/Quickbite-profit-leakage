// Step 7 tests: MongoDB validators and indexes, leak_notes CRUD with role
// checks, Redis cache (hit/miss, TTL, per-role keys, sorted-set leaderboard,
// invalidation). Runs against the live containers:
//   cd web && npm run test:step7
// Leaves no test data behind (test notes are deleted at the end).
import assert from 'node:assert/strict';
import { query, closeAll } from '../lib/mysql.js';
import { mongoDb, closeMongo } from '../lib/mongo.js';
import { createNote, listNotes, getNote, updateNote, deleteNote } from '../lib/leakNotes.js';
import { redis, closeRedis, invalidateAll, cacheKey, CACHE_TTL } from '../lib/cache.js';
import { monthlyKpi, restaurantLeakBoard, leakPareto } from '../lib/dashboard.js';

let passed = 0;
async function check(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`PASS  ${name}`);
  } catch (err) {
    console.log(`FAIL  ${name}\n      ${err.message}`);
    process.exitCode = 1;
  }
}
async function rejects(fn, status) {
  try { await fn(); } catch (err) {
    if (status && err.status !== status) throw new Error(`expected ${status}, got ${err.status}: ${err.message}`);
    return err;
  }
  throw new Error('expected an error, but the call succeeded');
}

const users = Object.fromEntries((await query('ADMIN',
  `SELECT r.role_name AS role, u.user_id AS id, u.email
     FROM app_user u JOIN app_role r ON r.role_id = u.role_id`)).map((u) => [u.role, u]));
const { ADMIN: admin, ANALYST: analyst, VIEWER: viewer } = users;
const db = await mongoDb();
const [leak] = await query('ADMIN',
  `SELECT lr.leakage_record_id AS id, lr.order_id, lt.leak_name
     FROM leakage_record lr JOIN leak_type lt ON lt.leak_type_id = lr.leak_type_id
    WHERE lt.leak_name = 'GATEWAY_FEE_EXCESS' ORDER BY lr.leakage_record_id DESC LIMIT 1`);
const [reco] = await query('ADMIN', 'SELECT recommendation_id AS id FROM recommendation LIMIT 1');

console.log('\n-- MongoDB: collections, validators, indexes');
await check('4 collections exist, each with a validator', async () => {
  const infos = await db.listCollections().toArray();
  for (const c of ['order_events', 'feedback', 'leak_notes', 'saved_scenarios']) {
    const info = infos.find((i) => i.name === c);
    assert.ok(info, `${c} missing`);
    assert.ok(info.options.validator?.$jsonSchema, `${c} has no validator`);
  }
});
await check('leak_notes indexes: type/time, order, tags, leak_ref, text', async () => {
  const names = (await db.collection('leak_notes').indexes()).map((i) => i.name);
  for (const n of ['ix_type_time', 'ix_order', 'ix_tags', 'ix_leak_ref', 'tx_title_body']) assert.ok(names.includes(n), n);
});
await check('validator rejects a note with no body (direct insert)', async () => {
  const err = await rejects(() => db.collection('leak_notes').insertOne({
    leak_ref: { kind: 'leakage_record', id: 1 }, leak_type: 'DELAY_COST', title: 'x y z', tags: [],
    status: 'OPEN', author: { user_id: 1, email: 'a@b.c' }, created_at: new Date(), updated_at: new Date() }));
  assert.equal(err.code, 121);
});
await check('validator rejects an unknown leak_type and an upper-case tag', async () => {
  const base = { leak_ref: { kind: 'leakage_record', id: 1 }, title: 'abc', body: 'b', status: 'OPEN',
    author: { user_id: 1, email: 'a@b.c' }, created_at: new Date(), updated_at: new Date() };
  assert.equal((await rejects(() => db.collection('leak_notes').insertOne({ ...base, leak_type: 'NOPE', tags: [] }))).code, 121);
  assert.equal((await rejects(() => db.collection('leak_notes').insertOne({ ...base, leak_type: 'DELAY_COST', tags: ['BAD'] }))).code, 121);
});
await check('feedback: rating 6 rejected; second review for order 1 rejected (unique index)', async () => {
  assert.equal((await rejects(() => db.collection('feedback').insertOne(
    { order_id: 99, customer_id: 1, rating: 6, created_at: new Date() }))).code, 121);
  assert.equal((await rejects(() => db.collection('feedback').insertOne(
    { order_id: 1, customer_id: 4780, rating: 4, created_at: new Date() }))).code, 11000);
});
await check('order_events accepts different payload shapes per event type', async () => {
  const types = await db.collection('order_events').distinct('event_type', { order_id: 2 });
  assert.deepEqual(types.sort(), ['PAYMENT_FAILED', 'PLACED', 'SUPPORT_CHAT']);
});

console.log('\n-- leak_notes CRUD');
let note;
await check('CREATE (analyst): leak_type and order_id copied from MySQL', async () => {
  note = await createNote(analyst, { leak_ref: { kind: 'leakage_record', id: leak.id },
    leak_type: 'DELAY_COST',                                   // ignored: MySQL decides
    title: 'Test note gateway', body: 'PAYU fee above 2%', tags: ['Test', 'gateway', 'test'] });
  assert.equal(note.leak_type, 'GATEWAY_FEE_EXCESS');
  assert.equal(note.order_id, leak.order_id);
  assert.deepEqual(note.tags, ['test', 'gateway']);             // lower-cased, de-duplicated
});
await check('CREATE linked to a recommendation (order_id null)', async () => {
  const n = await createNote(admin, { leak_ref: { kind: 'recommendation', id: reco.id },
    title: 'Test admin note', body: 'admin wrote this', tags: ['test'] });
  assert.equal(n.order_id, null);
});
await check('CREATE rejected: leakage_record that does not exist (404)', () =>
  rejects(() => createNote(analyst, { leak_ref: { kind: 'leakage_record', id: 999999999 }, title: 'abc', body: 'x' }), 404));
await check('CREATE rejected: viewer (403)', () =>
  rejects(() => createNote(viewer, { leak_ref: { kind: 'leakage_record', id: leak.id }, title: 'abc', body: 'x' }), 403));
await check('CREATE rejected: bad tag (400)', () =>
  rejects(() => createNote(analyst, { leak_ref: { kind: 'leakage_record', id: leak.id }, title: 'abc', body: 'x', tags: ['no spaces'] }), 400));
await check('READ list as viewer, filtered by leak type / order / tag / text', async () => {
  assert.ok((await listNotes(viewer, { leakType: 'GATEWAY_FEE_EXCESS' })).some((n) => n._id.equals(note._id)));
  assert.ok((await listNotes(viewer, { orderId: leak.order_id })).some((n) => n._id.equals(note._id)));
  assert.equal((await listNotes(viewer, { tag: 'test' })).length, 2);
  assert.ok((await listNotes(viewer, { q: 'PAYU' })).some((n) => n._id.equals(note._id)));
  assert.equal((await listNotes(viewer, { leakType: 'DELAY_COST', tag: 'test' })).length, 0);
});
await check('READ one note by id; bad id 400; unknown id 404', async () => {
  assert.equal((await getNote(viewer, note._id.toString())).title, 'Test note gateway');
  await rejects(() => getNote(viewer, 'not-an-id'), 400);
  await rejects(() => getNote(viewer, '0123456789abcdef01234567'), 404);
});
await check('UPDATE by the author: fields change, updated_at moves', async () => {
  await new Promise((r) => setTimeout(r, 5));
  const u = await updateNote(analyst, note._id.toString(), { status: 'RESOLVED', tags: ['test', 'done'] });
  assert.equal(u.status, 'RESOLVED');
  assert.deepEqual(u.tags, ['test', 'done']);
  assert.ok(u.updated_at > u.created_at);
});
await check('UPDATE rejected: viewer (403), bad status (400)', async () => {
  await rejects(() => updateNote(viewer, note._id.toString(), { status: 'OPEN' }), 403);
  await rejects(() => updateNote(analyst, note._id.toString(), { status: 'DONE' }), 400);
});
await check("UPDATE: analyst cannot edit the admin's note (403); admin can edit the analyst's", async () => {
  const [adminNote] = await listNotes(admin, { q: 'admin wrote' });
  await rejects(() => updateNote(analyst, adminNote._id.toString(), { status: 'RESOLVED' }), 403);
  assert.equal((await updateNote(admin, note._id.toString(), { status: 'INVESTIGATING' })).status, 'INVESTIGATING');
});
await check('DELETE: viewer 403; author deletes; note is gone (404)', async () => {
  await rejects(() => deleteNote(viewer, note._id.toString()), 403);
  assert.equal((await deleteNote(analyst, note._id.toString())).deleted, true);
  await rejects(() => getNote(viewer, note._id.toString()), 404);
});

console.log('\n-- Redis cache');
const r = await redis();
await check('invalidateAll() clears qb:* keys', async () => {
  await invalidateAll();
  let n = 0;
  for await (const k of r.scanIterator({ MATCH: 'qb:*' })) n += [k].flat().length;
  assert.equal(n, 0);
});
await check('monthly KPI: 1st call from MySQL, 2nd from Redis, same data, TTL set', async () => {
  const a = await monthlyKpi('VIEWER');
  const b = await monthlyKpi('VIEWER');
  assert.equal(a.source, 'mysql');
  assert.equal(b.source, 'redis');
  assert.deepEqual(b.data, a.data);
  assert.equal(a.data.length, 12);
  assert.ok(b.ttl > 0 && b.ttl <= CACHE_TTL, `ttl ${b.ttl}`);
});
await check('key holds the latest run id and the role; roles do not share entries', async () => {
  const v = await monthlyKpi('VIEWER');
  const a = await monthlyKpi('ANALYST');
  assert.equal(a.source, 'mysql');                             // analyst's own entry, not the viewer's
  assert.notEqual(v.key, a.key);
  const [{ run }] = await query('ADMIN', 'SELECT detection_run_id AS run FROM leakage_record ORDER BY leakage_record_id DESC LIMIT 1');
  assert.equal(v.key, cacheKey(run, 'VIEWER', 'kpi:monthly'));
  assert.notEqual(cacheKey('run-new', 'VIEWER', 'kpi:monthly'), v.key);   // a new run = a new key
});
await check('leaderboard is a Redis sorted set, ranked by leak, top = restaurant 121', async () => {
  const a = await restaurantLeakBoard('VIEWER', 5);
  const b = await restaurantLeakBoard('VIEWER', 5);
  assert.equal(a.source, 'mysql');
  assert.equal(b.source, 'redis');
  assert.equal(await r.type(a.key), 'zset');
  assert.ok((await r.zCard(a.key)) > 200);
  assert.equal(b.data[0].id, 121);
  assert.ok(b.data[0].score >= b.data[1].score);
});
await check('Pareto from cache: 3 leak types inside 80%', async () => {
  const p = await leakPareto('VIEWER');
  assert.equal(p.data.filter((x) => x.in_top_80).length, 3);
});
await check('after invalidateAll() the next call goes back to MySQL', async () => {
  assert.ok((await invalidateAll()) >= 4);
  assert.equal((await monthlyKpi('VIEWER')).source, 'mysql');
});

await db.collection('leak_notes').deleteMany({ tags: 'test' });
console.log(`\n${passed} passed${process.exitCode ? ', SOME FAILED' : ', all passed'}`);
await closeRedis();
await closeMongo();
await closeAll();
