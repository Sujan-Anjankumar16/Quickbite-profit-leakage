import { redirect } from 'next/navigation';
import { getSession } from '@/lib/session.js';

export default async function LoginPage({ searchParams }) {
  if (await getSession()) redirect('/');
  const { error } = await searchParams;
  return (
    <div className="login card">
      <h1>QuickBite login</h1>
      <p className="lead">Profit Leakage Analyzer</p>
      {error && <div className="alert err">Wrong email or password.</div>}
      {/* A plain HTML form: works without JavaScript; the API sets the cookie and redirects. */}
      <form action="/api/auth/login" method="post">
        <label>Email<input name="email" type="email" required autoComplete="username" /></label>
        <label>Password<input name="password" type="password" required autoComplete="current-password" /></label>
        <button className="primary" type="submit">Log in</button>
      </form>
      <p className="small muted">Demo logins are listed in the README.</p>
    </div>
  );
}
