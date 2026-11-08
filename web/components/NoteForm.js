'use client';
// Create a leak note: POST /api/notes.
import { useState } from 'react';
import { useRouter } from 'next/navigation';

export default function NoteForm({ statuses }) {
  const router = useRouter();
  const [msg, setMsg] = useState(null);
  async function submit(e) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const payload = {
      leak_ref: { kind: f.get('kind'), id: Number(f.get('refId')) },
      title: f.get('title'), body: f.get('body'), status: f.get('status'),
      tags: String(f.get('tags') ?? '').split(',').map((t) => t.trim()).filter(Boolean),
    };
    const res = await fetch('/api/notes', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) return setMsg({ ok: false, text: data.error ?? `Error ${res.status}` });
    e.target.reset();
    setMsg({ ok: true, text: `Saved (linked to ${data.note.leak_type}${data.note.order_id ? `, order ${data.note.order_id}` : ''}).` });
    router.refresh();
  }
  return (
    <form className="card" onSubmit={submit}>
      <div className="inline" style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <label>Linked to<select name="kind"><option value="leakage_record">leakage_record</option>
          <option value="recommendation">recommendation</option></select></label>
        <label>MySQL id<input name="refId" type="number" min="1" required style={{ width: 120 }} /></label>
        <label>Status<select name="status">{statuses.map((s) => <option key={s}>{s}</option>)}</select></label>
        <label style={{ flex: 1, minWidth: 220 }}>Title<input name="title" required minLength={3} maxLength={120} /></label>
      </div>
      <label style={{ marginTop: 8 }}>Note<textarea name="body" required maxLength={5000} /></label>
      <label style={{ marginTop: 8 }}>Tags (comma separated, a-z 0-9 -)<input name="tags" placeholder="refund, charge-back" /></label>
      <div style={{ marginTop: 10 }}><button className="primary" type="submit">Save note</button></div>
      {msg && <div className={`alert ${msg.ok ? 'ok' : 'err'}`}>{msg.text}</div>}
    </form>
  );
}
