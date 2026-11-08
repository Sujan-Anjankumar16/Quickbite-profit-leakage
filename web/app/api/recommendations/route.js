// GET /api/recommendations
import { route, json } from '@/lib/api.js';
import { listRecommendations } from '@/lib/recommendations.js';

export const GET = route(async (_req, _ctx, user) => json({ recommendations: await listRecommendations(user.role) }));
