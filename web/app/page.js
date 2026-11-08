// Overview: monthly KPIs and city scorecard (served from the Redis cache when warm).
import { requireUser } from '@/lib/session.js';
import { monthlyKpi, cityScorecard } from '@/lib/dashboard.js';
import Source from '@/components/Source.js';
import { inr, num } from '@/lib/format.js';

export default async function Overview() {
  const user = await requireUser();
  const [kpi, cities] = await Promise.all([monthlyKpi(user.role), cityScorecard(user.role)]);
  const rows = kpi.data;
  const total = (k) => rows.reduce((s, r) => s + Number(r[k] ?? 0), 0);
  const maxCpd = Math.max(...rows.map((r) => Number(r.contribution_per_delivered)));
  return (
    <>
      <h1>Overview</h1>
      <p className="lead">Orders and revenue keep growing while contribution (profit per order) falls.</p>
      <div className="grid2">
        <div className="card"><div className="muted small">Closed orders (12 months)</div><h1>{num(total('closed_orders'))}</h1></div>
        <div className="card"><div className="muted small">Revenue</div><h1>{inr(total('revenue'))}</h1></div>
        <div className="card"><div className="muted small">Contribution</div><h1>{inr(total('contribution'))}</h1></div>
        <div className="card"><div className="muted small">Loss on loss-making orders</div><h1 className="neg">{inr(total('total_loss'))}</h1></div>
      </div>

      <h2>Monthly KPIs <Source result={kpi} /></h2>
      <div className="scroll"><table>
        <thead><tr><th>Month</th><th className="n">Closed</th><th className="n">Cancel %</th><th className="n">GMV</th>
          <th className="n">Revenue</th><th className="n">Platform discount</th><th className="n">Delivery cost</th>
          <th className="n">Contribution</th><th className="n">Per delivered</th><th></th><th className="n">Loss-making</th></tr></thead>
        <tbody>{rows.map((r) => (
          <tr key={r.order_month}>
            <td>{r.order_month}</td><td className="n">{num(r.closed_orders)}</td><td className="n">{num(r.cancel_rate_pct, 2)}</td>
            <td className="n">{inr(r.gmv)}</td><td className="n">{inr(r.revenue)}</td><td className="n">{inr(r.platform_discount)}</td>
            <td className="n">{inr(r.delivery_cost)}</td><td className="n">{inr(r.contribution)}</td>
            <td className="n">{num(r.contribution_per_delivered, 2)}</td>
            <td style={{ width: 120 }}><div className="bar" style={{ width: `${(100 * r.contribution_per_delivered) / maxCpd}%` }} /></td>
            <td className="n">{num(r.loss_making_orders)}</td>
          </tr>))}
        </tbody>
      </table></div>

      <h2>Cities (worst contribution per order first) <Source result={cities} /></h2>
      <div className="scroll"><table>
        <thead><tr><th>City</th><th>State</th><th>Zone</th><th className="n">Closed orders</th><th className="n">Revenue</th>
          <th className="n">Contribution</th><th className="n">Per delivered</th><th className="n">Loss-making %</th></tr></thead>
        <tbody>{cities.data.map((c) => (
          <tr key={c.city_name}><td>{c.city_name}</td><td>{c.state_name}</td><td>{c.zone_name}</td>
            <td className="n">{num(c.closed_orders)}</td><td className="n">{inr(c.revenue)}</td><td className="n">{inr(c.contribution)}</td>
            <td className="n">{num(c.contribution_per_delivered, 2)}</td><td className="n">{num(c.loss_making_pct, 1)}</td></tr>))}
        </tbody>
      </table></div>
    </>
  );
}
