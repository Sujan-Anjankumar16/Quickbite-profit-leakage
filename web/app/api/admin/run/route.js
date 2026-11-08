// POST /api/admin/run: sp_detect_leaks + sp_generate_recommendations + cache clear. ADMIN only.
import { route, json } from '@/lib/api.js';
import { runDetection } from '@/lib/detection.js';

export const POST = route(async (_req, _ctx, user) => json({ run: await runDetection(user) }), { roles: ['ADMIN'] });
