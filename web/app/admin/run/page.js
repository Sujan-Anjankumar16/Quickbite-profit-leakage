// Admin only: run leak detection + recommendations, then clear the cache.
import { requireUser } from '@/lib/session.js';
import { query } from '@/lib/mysql.js';
import AccessDenied from '@/components/AccessDenied.js';
import RunButton from '@/components/RunButton.js';

export default async function RunPage() {
  const user = await requireUser();
  if (user.role !== 'ADMIN') return (<><h1>Run detection</h1><AccessDenied user={user} need="ADMIN" /></>);
  const runs = await query('ADMIN',
    `SELECT detection_run_id AS run_id, COUNT(*) AS leaks, SUM(is_primary) AS orders, MIN(detected_at) AS detected_at
       FROM leakage_record GROUP BY detection_run_id ORDER BY MIN(leakage_record_id) DESC LIMIT 5`);
  return (
    <>
      <h1>Run detection</h1>
      <p className="lead">Calls <code>sp_detect_leaks</code> over the whole data window, then
        <code> sp_generate_recommendations</code>, then clears the Redis cache. Each run is kept as history;
        recommendations still NEW are replaced.</p>
      <RunButton />
      <h2>Recent runs</h2>
      <table>
        <thead><tr><th>Run</th><th className="n">Leak rows</th><th className="n">Orders with a leak</th><th>Detected at</th></tr></thead>
        <tbody>{runs.map((r) => (<tr key={r.run_id}><td><code>{r.run_id}</code></td><td className="n">{r.leaks}</td>
          <td className="n">{r.orders}</td><td>{r.detected_at}</td></tr>))}</tbody>
      </table>
    </>
  );
}
