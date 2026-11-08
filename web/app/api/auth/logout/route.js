// POST /api/auth/logout: clears the session cookie.
import { NextResponse } from 'next/server';
import { COOKIE, cookieOptions } from '@/lib/session.js';

export async function POST(request) {
  const isJson = (request.headers.get('content-type') ?? '').includes('application/json');
  const res = isJson ? NextResponse.json({ ok: true }) : NextResponse.redirect(new URL('/login', request.url), 303);
  res.cookies.set(COOKIE, '', cookieOptions(0));
  return res;
}
