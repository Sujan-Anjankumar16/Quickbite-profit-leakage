// Seeds a few leak notes that point at REAL rows of the latest detection run.
// Run after sp_detect_leaks / sp_generate_recommendations:
//   cd web && npm run seed:notes
// Re-runnable: notes tagged "seed" are replaced.
import { query, closeAll } from '../lib/mysql.js';
import { mongoDb, closeMongo } from '../lib/mongo.js';
import { createNote } from '../lib/leakNotes.js';

async function appUser(email) {
  const [u] = await query('ADMIN',
    `SELECT u.user_id AS id, u.email, r.role_name AS role
       FROM app_user u JOIN app_role r ON r.role_id = u.role_id WHERE u.email = ?`, [email]);
  if (!u) throw new Error(`${email} not found: load 03_seed.sql first`);
  return u;
}

// The largest primary leak of a given type (optionally at one restaurant) in the latest run.
async function topLeak(leakName, restaurantId = null) {
  const [row] = await query('ADMIN',
    `SELECT lr.leakage_record_id AS id
       FROM leakage_record lr
       JOIN leak_type lt ON lt.leak_type_id = lr.leak_type_id
       JOIN orders o     ON o.order_id = lr.order_id
      WHERE lr.detection_run_id = (SELECT detection_run_id FROM leakage_record
                                   ORDER BY leakage_record_id DESC LIMIT 1)
        AND lr.is_primary AND lt.leak_name = ? AND (? IS NULL OR o.restaurant_id = ?)
      ORDER BY lr.leak_amount DESC LIMIT 1`, [leakName, restaurantId, restaurantId]);
  if (!row) throw new Error(`No ${leakName} leak found: run sp_detect_leaks first`);
  return row.id;
}

async function topRecommendation(leakTypeId) {
  const [row] = await query('ADMIN',
    `SELECT recommendation_id AS id FROM recommendation
      WHERE leak_type_id = ? ORDER BY priority_score DESC LIMIT 1`, [leakTypeId]);
  if (!row) throw new Error('No recommendations: run sp_generate_recommendations first');
  return row.id;
}

const analyst = await appUser('analyst@quickbite.dev');
const admin = await appUser('admin@quickbite.dev');
const db = await mongoDb();
const { deletedCount } = await db.collection('leak_notes').deleteMany({ tags: 'seed' });

const seeds = [
  [analyst, { leak_ref: { kind: 'leakage_record', id: await topLeak('UNRECOVERED_REFUND', 121) },
    title: 'Desi Coffee Roasters refunds never charged back',
    body: 'Quality refunds approved but recovered_amount is 0 on almost every order. Check the restaurant contract.',
    tags: ['seed', 'refund', 'charge-back'], status: 'INVESTIGATING' }],
  [analyst, { leak_ref: { kind: 'leakage_record', id: await topLeak('DISCOUNT_OVERSPEND') },
    title: 'FEAST60 stacked with FEASTFREE',
    body: 'Platform pays 60% plus free delivery on the same order. Stacking rule should block this.',
    tags: ['seed', 'coupon', 'stacking'], status: 'OPEN' }],
  [admin, { leak_ref: { kind: 'recommendation', id: await topRecommendation(5) },
    title: 'PAYU contract renewal raised the fee to 2.9%',
    body: 'Move default routing back to RAZORPAY/CASHFREE until PAYU agrees to 1.9%.',
    tags: ['seed', 'gateway'], status: 'OPEN' }],
];
for (const [user, note] of seeds) await createNote(user, note);

console.log(`leak_notes: removed ${deletedCount} old seed notes, inserted ${seeds.length}`);
await closeMongo();
await closeAll();
