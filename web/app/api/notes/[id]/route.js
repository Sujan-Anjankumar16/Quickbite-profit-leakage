// GET / PATCH / DELETE /api/notes/:id
import { route, json, body } from '@/lib/api.js';
import { getNote, updateNote, deleteNote } from '@/lib/leakNotes.js';

export const GET = route(async (_req, { params }, user) => json({ note: await getNote(user, (await params).id) }));

export const PATCH = route(async (request, { params }, user) =>
  json({ note: await updateNote(user, (await params).id, await body(request)) }));

export const DELETE = route(async (_req, { params }, user) => json(await deleteNote(user, (await params).id)));
