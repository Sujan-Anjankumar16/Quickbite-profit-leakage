// GET  /api/notes?leakType=&orderId=&tag=&status=&q=   list (all roles)
// POST /api/notes  { leak_ref: {kind, id}, title, body, tags, status }   (analyst, admin)
import { route, json, body } from '@/lib/api.js';
import { listNotes, createNote } from '@/lib/leakNotes.js';

export const GET = route(async (request, _ctx, user) => {
  const p = Object.fromEntries(new URL(request.url).searchParams);
  return json({ notes: await listNotes(user, p) });
});

export const POST = route(async (request, _ctx, user) => json({ note: await createNote(user, await body(request)) }, 201));
