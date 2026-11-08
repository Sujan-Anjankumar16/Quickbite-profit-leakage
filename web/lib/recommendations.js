// Recommendations: read for every role; status changes go to MySQL with the
// caller's OWN account. There is deliberately no role check here:
//   viewer  -> MySQL refuses (no UPDATE privilege)         -> 403 "Access denied by MySQL"
//   analyst -> allowed only on the status column (column-level GRANT)
//   admin   -> allowed
// and the trigger trg_recommendation_bu refuses illegal moves (-> 400).
import { query, withUser } from './mysql.js';
import { AppError, fromDbError } from './errors.js';

export const NEXT_STATUS = { NEW: ['ACCEPTED', 'REJECTED'], ACCEPTED: ['IMPLEMENTED', 'REJECTED'],
                             REJECTED: [], IMPLEMENTED: [] };

export function listRecommendations(role) {
  return query(role,
    `SELECT r.recommendation_id AS id, lt.leak_name, r.target_type, r.target_id,
            r.recommendation_text AS text, r.estimated_saving, r.demand_risk,
            r.priority_score, r.status, r.created_at
       FROM recommendation r LEFT JOIN leak_type lt ON lt.leak_type_id = r.leak_type_id
      ORDER BY FIELD(r.status, 'NEW', 'ACCEPTED', 'IMPLEMENTED', 'REJECTED'), r.priority_score DESC`);
}

export async function setStatus(user, id, status) {
  const n = Number(id);
  if (!Number.isInteger(n) || n < 1) throw new AppError(400, 'Bad recommendation id');
  if (!Object.keys(NEXT_STATUS).includes(status)) throw new AppError(400, 'Bad status');
  try {
    return await withUser(user.role, user.id, async (conn) => {
      const [res] = await conn.query('UPDATE recommendation SET status = ? WHERE recommendation_id = ?', [status, n]);
      if (res.affectedRows === 0) throw new AppError(404, `Recommendation ${n} not found`);
      const [[row]] = await conn.query('SELECT recommendation_id AS id, status FROM recommendation WHERE recommendation_id = ?', [n]);
      return row;
    });
  } catch (err) {
    throw fromDbError(err);
  }
}
