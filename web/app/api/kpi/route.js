// GET /api/kpi: monthly KPIs + city scorecard, from Redis when cached.
import { route, json } from '@/lib/api.js';
import { monthlyKpi, cityScorecard } from '@/lib/dashboard.js';

export const GET = route(async (_req, _ctx, user) => {
  const [monthly, cities] = await Promise.all([monthlyKpi(user.role), cityScorecard(user.role)]);
  return json({ monthly, cities });
});
