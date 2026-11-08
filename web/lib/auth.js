// Login against app_user (bcrypt). Only this lookup uses the ADMIN MySQL
// account, because no other role may read password_hash (02_roles.sql).
// Every attempt is written to audit_log with action LOGIN.
import bcrypt from 'bcryptjs';
import { query } from './mysql.js';

// A real bcrypt hash of a random string: comparing against it when the email
// is unknown makes "no such user" take as long as "wrong password".
const DUMMY_HASH = '$2b$10$258zPiWPO.cIE3v3S6l8HOeUIgvL07W2y2hEad6qdJiUMcaXoG9BO';

export async function login(email, password) {
  const e = String(email ?? '').trim().toLowerCase();
  const rows = await query('ADMIN',
    `SELECT u.user_id AS id, u.email, u.full_name AS name, u.password_hash, u.is_active,
            r.role_name AS role
       FROM app_user u JOIN app_role r ON r.role_id = u.role_id
      WHERE u.email = ?`, [e]);
  const u = rows[0];
  const ok = await bcrypt.compare(String(password ?? ''), u?.password_hash ?? DUMMY_HASH);
  const success = Boolean(u && ok && u.is_active);
  await query('ADMIN',
    `INSERT INTO audit_log (actor_user_id, entity_name, entity_id, action_name, new_values)
     VALUES (?, 'app_user', ?, 'LOGIN', JSON_OBJECT('success', ?, 'email', ?))`,
    [success ? u.id : null, u ? String(u.id) : 'unknown', success, e.slice(0, 120)]);
  return success ? { id: u.id, email: u.email, name: u.name, role: u.role } : null;
}
