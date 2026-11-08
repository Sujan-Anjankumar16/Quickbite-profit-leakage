// Leaks: Pareto of leak types (which make up 80%) and the restaurant leaderboard (Redis sorted set).
import { requireUser } from '@/lib/session.js';
import { leakPareto, restaurantLeakBoard } from '@/lib/dashboard.js';
import { latestRunId } from '@/lib/cache.js';
import Source from '@/components/Source.js';
import { inr, num } from '@/lib/format.js';

export default async function Leaks() {
  const user = await requireUser();
  const [pareto, board, run] = await Promise.all([leakPareto(user.role), restaurantLeakBoard(user.role, 10), latestRunId(user.role)]);
  const top = pareto.data.length ? Number(pareto.data[0].leak) : 1;
  return (
    <>
      <h1>Leaks</h1>
      <p className="lead">Primary leak per order in detection run <code>{run}</code> (each order counted once).</p>

      <h2>Leak types: Pareto <Source result={pareto} /></h2>
      <div className="scroll"><table>
        <thead><tr><th>Leak type</th><th className="n">Orders</th><th className="n">Leak</th><th></th>
          <th className="n">Share %</th><th className="n">Cumulative %</th><th>In the 80%</th></tr></thead>
        <tbody>{pareto.data.map((p) => (
          <tr key={p.leak_name}><td>{p.leak_name}</td><td className="n">{num(p.orders)}</td><td className="n">{inr(p.leak)}</td>
            <td style={{ width: 160 }}><div className="bar" style={{ width: `${(100 * p.leak) / top}%` }} /></td>
            <td className="n">{num(p.pct, 1)}</td><td className="n">{num(p.cum_pct, 1)}</td><td>{p.in_top_80 ? 'yes' : ''}</td></tr>))}
        </tbody>
      </table></div>

      <h2>Top 10 leaking restaurants <Source result={board} /></h2>
      <div className="scroll"><table>
        <thead><tr><th className="n">#</th><th>Restaurant</th><th>City</th><th className="n">Leak</th></tr></thead>
        <tbody>{board.data.map((b) => (
          <tr key={b.id}><td className="n">{b.rank}</td><td>{b.name} <span className="muted small">#{b.id}</span></td>
            <td>{b.city}</td><td className="n">{inr(b.score)}</td></tr>))}
        </tbody>
      </table></div>
    </>
  );
}
