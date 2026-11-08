// Sessions in a signed cookie: base64url(JSON payload) + "." + HMAC-SHA256(payload, AUTH_SECRET).
// The browser can read nothing useful (httpOnly) and cannot change its role:
// any edit breaks the signature and the session is rejected.
import crypto from 'node:crypto';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';

export const COOKIE = 'qb_session';
const MAX_AGE = 8 * 3600;                         // 8 hours

function secret() {
  const s = process.env.AUTH_SECRET;
  if (!s || s.length < 16) throw new Error('AUTH_SECRET is missing or too short (set it in .env)');
  return s;
}

const mac = (body) => crypto.createHmac('sha256', secret()).update(body).digest('base64url');

export function sign(user) {
  const payload = { id: user.id, email: user.email, name: user.name, role: user.role,
                    exp: Math.floor(Date.now() / 1000) + MAX_AGE };
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  return `${body}.${mac(body)}`;
}

export function verify(token) {
  if (!token || typeof token !== 'string') return null;
  const [body, sig] = token.split('.');
  if (!body || !sig) return null;
  const a = Buffer.from(sig);
  const b = Buffer.from(mac(body));
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;   // constant-time compare
  try {
    const p = JSON.parse(Buffer.from(body, 'base64url').toString());
    return p.exp > Date.now() / 1000 ? p : null;
  } catch {
    return null;
  }
}

export function cookieOptions(maxAge = MAX_AGE) {
  return { httpOnly: true, sameSite: 'lax', path: '/', maxAge,
           secure: process.env.COOKIE_SECURE === '1' };   // set to 1 behind HTTPS
}

export async function getSession() {
  return verify((await cookies()).get(COOKIE)?.value);
}

// For pages: no session -> login page.
export async function requireUser() {
  const user = await getSession();
  if (!user) redirect('/login');
  return user;
}
