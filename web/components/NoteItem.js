'use client';
// One leak note with Edit (PATCH /api/notes/:id) and Delete (DELETE /api/notes/:id).
import { useState } from 'react';
import { useRouter } from 'next/navigation';

export default function NoteItem({ note, user, statuses }) {
  const router = useRouter();
  const [editing, setEditing] = useState(false);
  const [error, setError] = useState('');
  async function call(method, payload) {
    setError('');
    const res = await fetch(`/api/notes/${note._id}`, { method, headers: { 'content-type': 'application/json' },
      body: payload ? JSON.stringify(payload) : undefined });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) { setError(data.error ?? `Error ${res.status}`); return false; }
    router.refresh();
    return true;
  }
  async function save(e) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const ok = await call('PATCH', { title: f.get('title'), body: f.get('body'), status: f.get('status'),
      tags: String(f.get('tags') ?? '').split(',').map((t) => t.trim()).filter(Boolean) });
    if (ok) setEditing(false);
  }
  const mine = user.role === 'ADMIN' || note.author.user_id === user.id;
  return (
    <div className="card">
      {editing ? (
        <form onSubmit={save}>
          <label>Title<input name="title" defaultValue={note.title} required /></label>
          <label style={{ marginTop: 6 }}>Note<textarea name="body" defaultValue={note.body} required /></label>
          <div className="inline" style={{ display: 'flex', gap: 8, marginTop: 6 }}>
            <label>Status<select name="status" defaultValue={note.status}>{statuses.map((s) => <option key={s}>{s}</option>)}</select></label>
            <label style={{ flex: 1 }}>Tags<input name="tags" defaultValue={note.tags.join(', ')} /></label>
          </div>
          <div className="btns" style={{ marginTop: 8 }}><button className="primary" type="submit">Save</button>
            <button type="button" onClick={() => setEditing(false)}>Cancel</button></div>
        </form>
      ) : (
        <>
          <strong>{note.title}</strong> <span className="badge">{note.status}</span>{' '}
          <span className="small muted">{note.leak_type} · {note.leak_ref.kind} #{note.leak_ref.id}
            {note.order_id ? ` · order ${note.order_id}` : ''} · by {note.author.email} · {new Date(note.updated_at).toLocaleString('en-IN')}</span>
          <p style={{ margin: '6px 0' }}>{note.body}</p>
          <div>{note.tags.map((t) => <span key={t} className="tag">{t}</span>)}</div>
          <div className="btns" style={{ marginTop: 8 }}>
            <button onClick={() => setEditing(true)}>Edit</button>
            <button className="danger" onClick={() => call('DELETE')}>Delete</button>
            {!mine && <span className="small muted">(only the author or an admin can change this)</span>}
          </div>
        </>
      )}
      {error && <div className="alert err small">{error}</div>}
    </div>
  );
}
