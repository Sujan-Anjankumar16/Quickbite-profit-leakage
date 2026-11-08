// =====================================================================
//  QuickBite  -  db/mongo/01_init.js   (MongoDB 7, run by mongosh)
//  NoSQL creation (rubric item 2: "NoSQL database creation", 4 marks)
//
//  Four collections, each with a $jsonSchema validator (validationAction
//  "error": MongoDB REJECTS a document that breaks the schema) and indexes:
//    order_events     append-only timeline of what happened to an order
//    feedback         one customer review per order, free text + tags
//    leak_notes       analyst notes on a MySQL leak or recommendation (full CRUD in the app)
//    saved_scenarios  "what if" settings an analyst saved, with their results
//  Links to MySQL are plain ids (order_id, leakage_record id, recommendation id).
//  MongoDB cannot enforce a foreign key into MySQL, so the API checks the id
//  exists in MySQL before it writes a leak note.
//
//  Runs automatically on an EMPTY mongo volume (docker-entrypoint-initdb.d).
//  Re-runnable by hand: existing collections get their validator updated
//  (collMod), createIndex is idempotent, seed rows are replaced.
//    docker compose exec mongo mongosh --quiet quickbite /docker-entrypoint-initdb.d/01_init.js
//  leak_notes are seeded later by web/scripts/seed-leak-notes.mjs, because a
//  note must point at a real leakage_record id, which only exists after
//  the MySQL detection run.
// =====================================================================
db = db.getSiblingDB('quickbite');

const LEAK_TYPES = ['DISCOUNT_OVERSPEND', 'DELIVERY_COST_OVERRUN', 'DELAY_COST',
                    'UNRECOVERED_REFUND', 'GATEWAY_FEE_EXCESS', 'LOW_VALUE_ORDER'];
const ID = { bsonType: ['int', 'long'], minimum: 1 };
const AUTHOR = {
  bsonType: 'object',
  required: ['user_id', 'email'],
  additionalProperties: false,
  properties: { user_id: ID, email: { bsonType: 'string', pattern: '^[^@\\s]+@[^@\\s]+$' } },
};

// Create the collection with its validator, or update the validator if it exists.
function ensureCollection(name, schema) {
  const options = { validator: { $jsonSchema: schema }, validationLevel: 'strict', validationAction: 'error' };
  if (db.getCollectionNames().includes(name)) {
    db.runCommand({ collMod: name, ...options });
  } else {
    db.createCollection(name, options);
  }
}

// ---------------------------------------------------------------------
// 1. order_events: flexible payload per event type (the reason this is NoSQL:
//    a PAYMENT_FAILED event carries different fields from a SUPPORT_CHAT one)
// ---------------------------------------------------------------------
ensureCollection('order_events', {
  bsonType: 'object',
  required: ['order_id', 'event_type', 'at', 'actor'],
  properties: {
    order_id:   ID,
    event_type: { enum: ['PLACED', 'ACCEPTED', 'PREPARING', 'PICKED_UP', 'DELIVERED', 'CANCELLED',
                         'PAYMENT_FAILED', 'REFUND_REQUESTED', 'SUPPORT_CHAT'] },
    at:         { bsonType: 'date' },
    actor:      { enum: ['CUSTOMER', 'RESTAURANT', 'PARTNER', 'SYSTEM', 'AGENT'] },
    payload:    { bsonType: 'object' },
  },
});
db.order_events.createIndex({ order_id: 1, at: 1 }, { name: 'ix_order_time' });
db.order_events.createIndex({ event_type: 1, at: -1 }, { name: 'ix_type_time' });

// ---------------------------------------------------------------------
// 2. feedback: one review per order
// ---------------------------------------------------------------------
ensureCollection('feedback', {
  bsonType: 'object',
  required: ['order_id', 'customer_id', 'rating', 'created_at'],
  additionalProperties: false,
  properties: {
    _id:         { bsonType: 'objectId' },
    order_id:    ID,
    customer_id: ID,
    rating:      { bsonType: 'int', minimum: 1, maximum: 5 },
    comment:     { bsonType: 'string', maxLength: 1000 },
    tags:        { bsonType: 'array', maxItems: 10, uniqueItems: true, items: { bsonType: 'string' } },
    created_at:  { bsonType: 'date' },
  },
});
db.feedback.createIndex({ order_id: 1 }, { name: 'uq_feedback_order', unique: true });
db.feedback.createIndex({ rating: 1, created_at: -1 }, { name: 'ix_rating_time' });
db.feedback.createIndex({ tags: 1 }, { name: 'ix_tags' });                          // multikey

// ---------------------------------------------------------------------
// 3. leak_notes: the CRUD feature
// ---------------------------------------------------------------------
ensureCollection('leak_notes', {
  bsonType: 'object',
  required: ['leak_ref', 'leak_type', 'title', 'body', 'tags', 'status', 'author', 'created_at', 'updated_at'],
  additionalProperties: false,
  properties: {
    _id:        { bsonType: 'objectId' },
    leak_ref:   {                                                 // what in MySQL this note is about
      bsonType: 'object',
      required: ['kind', 'id'],
      additionalProperties: false,
      properties: { kind: { enum: ['leakage_record', 'recommendation'] }, id: ID },
    },
    leak_type:  { enum: LEAK_TYPES },
    order_id:   { bsonType: ['int', 'long', 'null'] },            // null for a recommendation note
    title:      { bsonType: 'string', minLength: 3, maxLength: 120 },
    body:       { bsonType: 'string', minLength: 1, maxLength: 5000 },
    tags:       { bsonType: 'array', maxItems: 10, uniqueItems: true,
                  items: { bsonType: 'string', pattern: '^[a-z0-9-]{2,30}$' } },
    status:     { enum: ['OPEN', 'INVESTIGATING', 'RESOLVED'] },
    author:     AUTHOR,
    created_at: { bsonType: 'date' },
    updated_at: { bsonType: 'date' },
  },
});
db.leak_notes.createIndex({ leak_type: 1, created_at: -1 }, { name: 'ix_type_time' });
db.leak_notes.createIndex({ order_id: 1 }, { name: 'ix_order' });
db.leak_notes.createIndex({ tags: 1 }, { name: 'ix_tags' });                          // multikey
db.leak_notes.createIndex({ 'leak_ref.kind': 1, 'leak_ref.id': 1 }, { name: 'ix_leak_ref' });
db.leak_notes.createIndex({ title: 'text', body: 'text' }, { name: 'tx_title_body' }); // full-text search

// ---------------------------------------------------------------------
// 4. saved_scenarios: free-form parameters and results of a what-if
// ---------------------------------------------------------------------
ensureCollection('saved_scenarios', {
  bsonType: 'object',
  required: ['name', 'created_by', 'params', 'created_at'],
  additionalProperties: false,
  properties: {
    _id:        { bsonType: 'objectId' },
    name:       { bsonType: 'string', minLength: 3, maxLength: 80 },
    created_by: AUTHOR,
    params:     { bsonType: 'object' },
    results:    { bsonType: 'object' },
    created_at: { bsonType: 'date' },
  },
});
db.saved_scenarios.createIndex({ 'created_by.user_id': 1, name: 1 }, { name: 'uq_owner_name', unique: true });

// ---------------------------------------------------------------------
// 5. Seed data (small, static). Orders 1-5 and their customers are fixed by
//    the generator's seed (2026): order 1 -> customer 4780, 2 -> 1251, 3 -> 1919,
//    4 -> 3614, 5 -> 4587.
// ---------------------------------------------------------------------
db.order_events.deleteMany({ 'payload.seed': true });
const t0 = ISODate('2025-11-01T12:10:00Z');
const min = (m) => new Date(t0.getTime() + m * 60000);
db.order_events.insertMany([
  { order_id: 1, event_type: 'PLACED',     at: min(0),  actor: 'CUSTOMER',   payload: { seed: true, channel: 'android' } },
  { order_id: 1, event_type: 'ACCEPTED',   at: min(2),  actor: 'RESTAURANT', payload: { seed: true, prep_promise_min: 18 } },
  { order_id: 1, event_type: 'PICKED_UP',  at: min(24), actor: 'PARTNER',    payload: { seed: true, waited_min: 6 } },
  { order_id: 1, event_type: 'DELIVERED',  at: min(41), actor: 'PARTNER',    payload: { seed: true, photo_proof: true } },
  { order_id: 2, event_type: 'PLACED',     at: min(5),  actor: 'CUSTOMER',   payload: { seed: true, channel: 'web' } },
  { order_id: 2, event_type: 'PAYMENT_FAILED', at: min(6), actor: 'SYSTEM',  payload: { seed: true, gateway: 'PAYU', code: 'BANK_TIMEOUT', retry: true } },
  { order_id: 2, event_type: 'SUPPORT_CHAT', at: min(50), actor: 'AGENT',    payload: { seed: true, minutes: 7, topic: 'missing item', transcript_id: 'CH-1002' } },
  { order_id: 3, event_type: 'REFUND_REQUESTED', at: min(70), actor: 'CUSTOMER', payload: { seed: true, reason: 'QUALITY', photos: 2 } },
]);

db.feedback.deleteMany({ order_id: { $in: [1, 2, 3, 4, 5] } });
db.feedback.insertMany([
  { order_id: 1, customer_id: 4780, rating: 5, comment: 'Hot and on time.', tags: ['on-time'], created_at: min(60) },
  { order_id: 2, customer_id: 1251, rating: 2, comment: 'Raita was missing, chat took long.', tags: ['missing-item', 'support'], created_at: min(90) },
  { order_id: 3, customer_id: 1919, rating: 1, comment: 'Food was cold and soggy.', tags: ['quality', 'late'], created_at: min(95) },
  { order_id: 4, customer_id: 3614, rating: 4, created_at: min(100) },
  { order_id: 5, customer_id: 4587, rating: 3, comment: 'Okay, packaging leaked.', tags: ['packaging'], created_at: min(120) },
]);

db.saved_scenarios.deleteMany({ 'created_by.email': 'analyst@quickbite.dev' });
db.saved_scenarios.insertOne({
  name: 'Cap FEAST60 at Rs 80',
  created_by: { user_id: 2, email: 'analyst@quickbite.dev' },
  params: { coupon_code: 'FEAST60', max_discount_amount: 80, min_basket: 199 },
  results: { est_monthly_saving: 21500, est_order_drop_pct: 3.5, note: 'hand-entered estimate' },
  created_at: ISODate('2026-11-01T10:00:00Z'),
});

printjson({
  collections: db.getCollectionNames().sort(),
  order_events: db.order_events.countDocuments(),
  feedback: db.feedback.countDocuments(),
  leak_notes: db.leak_notes.countDocuments(),
  saved_scenarios: db.saved_scenarios.countDocuments(),
});
