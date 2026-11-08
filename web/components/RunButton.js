'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';

export default function RunButton() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  async function run() {
    setBusy(true); setMsg(null);
    const res = await fetch('/api/admin/run', { method: 'POST' });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) return setMsg({ ok: false, text: data.error ?? `Error ${res.status}` });
    const r = data.run;
    setMsg({ ok: true, text: `Run ${r.run_id}: ${r.leaks} leak rows, ${r.recommendations} recommendations, ${r.cacheKeysCleared} cache keys cleared, ${r.seconds.toFixed(1)} s.` });
    router.refresh();
  }
  return (
    <div className="card">
      <button className="primary" disabled={busy} onClick={run}>{busy ? 'Running... (about 5 s)' : 'Run detection now'}</button>
      {msg && <div className={`alert ${msg.ok ? 'ok' : 'err'}`}>{msg.text}</div>}
    </div>
  );
}
