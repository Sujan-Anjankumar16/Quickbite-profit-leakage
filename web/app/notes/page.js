// Leak notes (MongoDB): filter, create, edit, delete. Viewers can read; their
// write attempts get a clear "access denied" from the API.
import { requireUser } from '@/lib/session.js';
import { listNotes, LEAK_TYPES, NOTE_STATUSES } from '@/lib/leakNotes.js';
import NoteForm from '@/components/NoteForm.js';
import NoteItem from '@/components/NoteItem.js';
import { AppError } from '@/lib/errors.js';

export default async function Notes({ searchParams }) {
  const user = await requireUser();
  const f = await searchParams;
  let notes = [];
  let error = '';
  try {
    notes = await listNotes(user, f);
  } catch (e) {
    if (!(e instanceof AppError)) throw e;
    error = e.message;
  }
  const plain = JSON.parse(JSON.stringify(notes));            // ObjectId/Date -> strings for the client
  return (
    <>
      <h1>Leak notes</h1>
      <p className="lead">Analyst notes stored in MongoDB, each linked to a MySQL leak record or recommendation.
        {user.role === 'VIEWER' && ' You are a viewer: you can read notes but not change them.'}</p>

      <form className="inline card" method="get">
        <label>Leak type<select name="leakType" defaultValue={f.leakType ?? ''}>
          <option value="">any</option>{LEAK_TYPES.map((t) => <option key={t}>{t}</option>)}</select></label>
        <label>Order id<input name="orderId" type="number" min="1" defaultValue={f.orderId ?? ''} style={{ width: 110 }} /></label>
        <label>Tag<input name="tag" defaultValue={f.tag ?? ''} style={{ width: 120 }} /></label>
        <label>Status<select name="status" defaultValue={f.status ?? ''}>
          <option value="">any</option>{NOTE_STATUSES.map((s) => <option key={s}>{s}</option>)}</select></label>
        <label>Text search<input name="q" defaultValue={f.q ?? ''} /></label>
        <button type="submit">Filter</button> <a href="/notes" className="small">clear</a>
      </form>
      {error && <div className="alert err">{error}</div>}

      <h2>{plain.length} note{plain.length === 1 ? '' : 's'}</h2>
      {plain.map((n) => <NoteItem key={n._id} note={n} user={user} statuses={NOTE_STATUSES} />)}

      <h2>New note</h2>
      <NoteForm statuses={NOTE_STATUSES} />
    </>
  );
}
