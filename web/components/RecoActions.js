'use client';
// Status buttons for one recommendation. Shows the server's message on failure
// (for a viewer: "Access denied by MySQL: UPDATE command denied ...").
import { useState } from 'react';
import { useRouter } from 'next/navigation';

export default function RecoActions({ id, next }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  if (!next.length) return <span className="muted small">final</span>;
  async function change(status) {
    setBusy(true); setError('');
    const res = await fetch(`/api/recommendations/${id}`, {
      method: 'PATCH', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ status }) });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) setError(data.error ?? `Error ${res.status}`);
    else router.refresh();
  }
  return (
    <div>
      <div className="btns">{next.map((s) => (
        <button key={s} disabled={busy} onClick={() => change(s)}>{s === 'REJECTED' ? 'Reject' : s === 'ACCEPTED' ? 'Accept' : 'Implemented'}</button>))}
      </div>
      {error && <div className="alert err small">{error}</div>}
    </div>
  );
}
