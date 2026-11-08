// Wrapper for API route handlers: session check, optional role check, and
// one place that turns errors into JSON with the right HTTP status.
import { NextResponse } from 'next/server';
import { getSession } from './session.js';
import { AppError, fromDbError } from './errors.js';

export const json = (data, status = 200) => NextResponse.json(data, { status });

export function route(handler, { roles } = {}) {
  return async (request, context) => {
    try {
      const user = await getSession();
      if (!user) return json({ error: 'Not logged in' }, 401);
      if (roles && !roles.includes(user.role)) {
        return json({ error: `Access denied: ${roles.join(' or ')} only (you are ${user.role})` }, 403);
      }
      return await handler(request, context, user);
    } catch (e) {
      const err = fromDbError(e);
      if (err instanceof AppError) return json({ error: err.message }, err.status);
      console.error(e);
      return json({ error: 'Server error' }, 500);
    }
  };
}

export async function body(request) {
  try {
    return await request.json();
  } catch {
    throw new AppError(400, 'Request body must be JSON');
  }
}
