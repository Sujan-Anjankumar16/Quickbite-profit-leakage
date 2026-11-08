// Recommendations: everyone reads; status buttons call PATCH /api/recommendations/:id.
// Viewers see the buttons too, so the demo shows MySQL itself refusing them.
import { requireUser } from '@/lib/session.js';
import { listRecommendations, NEXT_STATUS } from '@/lib/recommendations.js';
import RecoActions from '@/components/RecoActions.js';
import { inr, num } from '@/lib/format.js';

export default async function Recommendations() {
  const user = await requireUser();
  const recos = await listRecommendations(user.role);
  return (
    <>
      <h1>Recommendations</h1>
      <p className="lead">Ranked by priority (estimated saving discounted by demand risk).
        {user.role === 'VIEWER' && ' You are a viewer: status changes will be refused by the database.'}</p>
      <div className="scroll"><table>
        <thead><tr><th className="n">Priority</th><th>Leak type</th><th>Target</th><th>Recommendation</th>
          <th className="n">Est. saving</th><th>Risk</th><th>Status</th><th>Change status</th></tr></thead>
        <tbody>{recos.map((r) => (
          <tr key={r.id}>
            <td className="n">{num(r.priority_score, 1)}</td><td className="small">{r.leak_name}</td>
            <td className="small">{r.target_type}{r.target_id ? ` #${r.target_id}` : ''}</td>
            <td>{r.text}</td><td className="n">{inr(r.estimated_saving)}</td><td>{r.demand_risk}</td>
            <td><strong>{r.status}</strong></td>
            <td><RecoActions id={r.id} next={NEXT_STATUS[r.status]} /></td>
          </tr>))}
        </tbody>
      </table></div>
    </>
  );
}
