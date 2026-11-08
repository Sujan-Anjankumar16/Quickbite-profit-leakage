// GET /api/leaks: Pareto of leak types + restaurant leaderboard (Redis sorted set).
import { route, json } from '@/lib/api.js';
import { leakPareto, restaurantLeakBoard } from '@/lib/dashboard.js';

export const GET = route(async (_req, _ctx, user) => {
  const [pareto, leaderboard] = await Promise.all([leakPareto(user.role), restaurantLeakBoard(user.role, 10)]);
  return json({ pareto, leaderboard });
});
