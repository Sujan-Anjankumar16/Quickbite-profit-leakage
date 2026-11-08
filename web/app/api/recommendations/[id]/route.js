// PATCH /api/recommendations/:id  { status }
// No app-level role check on purpose: the role's MySQL account decides
// (viewer -> "UPDATE command denied" -> 403). The trigger checks the move.
import { route, json, body } from '@/lib/api.js';
import { setStatus } from '@/lib/recommendations.js';

export const PATCH = route(async (request, { params }, user) => {
  const { id } = await params;
  const { status } = await body(request);
  return json({ recommendation: await setStatus(user, id, status) });
});
