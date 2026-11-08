// POST /api/auth/login  { email, password }  (JSON, or a plain HTML form)
// Success: sets the signed session cookie. JSON -> 200 {user}; form -> redirect to /.
import { NextResponse } from 'next/server';
import { login } from '@/lib/auth.js';
import { COOKIE, sign, cookieOptions } from '@/lib/session.js';

export async function POST(request) {
  const isJson = (request.headers.get('content-type') ?? '').includes('application/json');
  let email, password;
  try {
    if (isJson) ({ email, password } = await request.json());
    else { const f = await request.formData(); email = f.get('email'); password = f.get('password'); }
  } catch {
    return NextResponse.json({ error: 'Bad request' }, { status: 400 });
  }
  const user = await login(email, password);
  if (!user) {
    return isJson
      ? NextResponse.json({ error: 'Wrong email or password' }, { status: 401 })
      : NextResponse.redirect(new URL('/login?error=1', request.url), 303);
  }
  const res = isJson ? NextResponse.json({ user }) : NextResponse.redirect(new URL('/', request.url), 303);
  res.cookies.set(COOKIE, sign(user), cookieOptions());
  return res;
}
