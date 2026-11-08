// leak_notes: full CRUD on MongoDB, linked to MySQL by id.
//   Create  analyst/admin; the linked leakage_record or recommendation must
//           exist in MySQL; leak_type and order_id are copied FROM MySQL, so a
//           note can never claim the wrong leak type.
//   Read    every role (list with filters, or one note)
//   Update  the author, or any admin (title, body, tags, status only)
//   Delete  the author, or any admin
// The collection's $jsonSchema validator (db/mongo/01_init.js) is the last
// line of defence: even a bug here cannot store a malformed note.
import { ObjectId } from 'mongodb';
import { mongoDb } from './mongo.js';
import { query } from './mysql.js';
import { AppError, fromDbError } from './errors.js';

export const LEAK_TYPES = ['DISCOUNT_OVERSPEND', 'DELIVERY_COST_OVERRUN', 'DELAY_COST',
                           'UNRECOVERED_REFUND', 'GATEWAY_FEE_EXCESS', 'LOW_VALUE_ORDER'];
export const NOTE_STATUSES = ['OPEN', 'INVESTIGATING', 'RESOLVED'];

const notes = async () => (await mongoDb()).collection('leak_notes');

function requireWriter(user) {
  if (!['ANALYST', 'ADMIN'].includes(user.role)) {
    throw new AppError(403, 'Access denied: viewers can read leak notes but not change them');
  }
}

function requireOwnerOrAdmin(user, note) {
  if (user.role !== 'ADMIN' && note.author.user_id !== user.id) {
    throw new AppError(403, 'Access denied: only the author or an admin can change this note');
  }
}

function toObjectId(id) {
  if (!ObjectId.isValid(id)) throw new AppError(400, 'Invalid note id');
  return new ObjectId(id);
}

function cleanTags(tags) {
  if (tags === undefined) return undefined;
  if (!Array.isArray(tags)) throw new AppError(400, 'tags must be a list');
  const out = [...new Set(tags.map((t) => String(t).trim().toLowerCase()).filter(Boolean))];
  if (out.length > 10) throw new AppError(400, 'At most 10 tags');
  for (const t of out) {
    if (!/^[a-z0-9-]{2,30}$/.test(t)) throw new AppError(400, `Bad tag "${t}" (2-30 chars: a-z, 0-9, -)`);
  }
  return out;
}

function cleanText(value, field, min, max) {
  if (value === undefined) return undefined;
  const s = String(value).trim();
  if (s.length < min || s.length > max) throw new AppError(400, `${field} must be ${min}-${max} characters`);
  return s;
}

// Look the linked row up in MySQL (as the caller's role) and return its facts.
async function resolveRef(role, kind, id) {
  const n = Number(id);
  if (!Number.isInteger(n) || n < 1) throw new AppError(400, 'leak_ref.id must be a positive integer');
  try {
    if (kind === 'leakage_record') {
      const rows = await query(role,
        `SELECT lr.order_id, lt.leak_name
           FROM leakage_record lr JOIN leak_type lt ON lt.leak_type_id = lr.leak_type_id
          WHERE lr.leakage_record_id = ?`, [n]);
      if (!rows.length) throw new AppError(404, `leakage_record ${n} does not exist in MySQL`);
      return { id: n, leak_type: rows[0].leak_name, order_id: rows[0].order_id };
    }
    if (kind === 'recommendation') {
      const rows = await query(role,
        `SELECT lt.leak_name
           FROM recommendation r LEFT JOIN leak_type lt ON lt.leak_type_id = r.leak_type_id
          WHERE r.recommendation_id = ?`, [n]);
      if (!rows.length) throw new AppError(404, `recommendation ${n} does not exist in MySQL`);
      if (!rows[0].leak_name) throw new AppError(400, `recommendation ${n} has no leak type`);
      return { id: n, leak_type: rows[0].leak_name, order_id: null };
    }
  } catch (err) {
    throw fromDbError(err);
  }
  throw new AppError(400, 'leak_ref.kind must be leakage_record or recommendation');
}

export async function createNote(user, input) {
  requireWriter(user);
  const ref = await resolveRef(user.role, input?.leak_ref?.kind, input?.leak_ref?.id);
  const status = input.status ?? 'OPEN';
  if (!NOTE_STATUSES.includes(status)) throw new AppError(400, 'Bad status');
  const now = new Date();
  const doc = {
    leak_ref: { kind: input.leak_ref.kind, id: ref.id },
    leak_type: ref.leak_type,
    order_id: ref.order_id,
    title: cleanText(input.title, 'title', 3, 120),
    body: cleanText(input.body, 'body', 1, 5000),
    tags: cleanTags(input.tags ?? []),
    status,
    author: { user_id: user.id, email: user.email },
    created_at: now,
    updated_at: now,
  };
  if (!doc.title || !doc.body) throw new AppError(400, 'title and body are required');
  try {
    const res = await (await notes()).insertOne(doc);
    return { ...doc, _id: res.insertedId };
  } catch (err) {
    throw fromDbError(err);
  }
}

// filters: leakType, orderId, tag, status, q (full-text on title + body), limit
export async function listNotes(user, filters = {}) {
  const f = {};
  if (filters.leakType) {
    if (!LEAK_TYPES.includes(filters.leakType)) throw new AppError(400, 'Unknown leak type');
    f.leak_type = filters.leakType;
  }
  if (filters.orderId) f.order_id = Number(filters.orderId);
  if (filters.tag) f.tags = String(filters.tag).toLowerCase();            // matches inside the array
  if (filters.status) f.status = filters.status;
  if (filters.q) f.$text = { $search: String(filters.q) };
  const limit = Math.min(Number(filters.limit) || 50, 200);
  return (await notes()).find(f).sort({ created_at: -1 }).limit(limit).toArray();
}

export async function getNote(user, id) {
  const note = await (await notes()).findOne({ _id: toObjectId(id) });
  if (!note) throw new AppError(404, 'Note not found');
  return note;
}

export async function updateNote(user, id, patch) {
  requireWriter(user);
  const note = await getNote(user, id);
  requireOwnerOrAdmin(user, note);
  const set = { updated_at: new Date() };
  if (patch.title !== undefined) set.title = cleanText(patch.title, 'title', 3, 120);
  if (patch.body !== undefined) set.body = cleanText(patch.body, 'body', 1, 5000);
  if (patch.tags !== undefined) set.tags = cleanTags(patch.tags);
  if (patch.status !== undefined) {
    if (!NOTE_STATUSES.includes(patch.status)) throw new AppError(400, 'Bad status');
    set.status = patch.status;
  }
  try {
    return await (await notes()).findOneAndUpdate({ _id: note._id }, { $set: set }, { returnDocument: 'after' });
  } catch (err) {
    throw fromDbError(err);
  }
}

export async function deleteNote(user, id) {
  requireWriter(user);
  const note = await getNote(user, id);
  requireOwnerOrAdmin(user, note);
  await (await notes()).deleteOne({ _id: note._id });
  return { deleted: true, _id: note._id };
}
