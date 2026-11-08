// GET /api/me: who is logged in (from the signed cookie).
import { route, json } from '@/lib/api.js';

export const GET = route(async (_req, _ctx, user) => json({ user }));
