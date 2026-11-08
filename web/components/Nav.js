// Top bar. "Run detection" is listed for admins only (the page itself checks too).
export default function Nav({ user }) {
  return (
    <nav className="top">
      <span className="brand">QuickBite</span>
      <a href="/">Overview</a>
      <a href="/leaks">Leaks</a>
      <a href="/recommendations">Recommendations</a>
      <a href="/notes">Leak notes</a>
      {user.role === 'ADMIN' && <a href="/admin/run">Run detection</a>}
      <span className="who">
        {user.name} <span className="role">{user.role}</span>
        <form action="/api/auth/logout" method="post"><button type="submit">Log out</button></form>
      </span>
    </nav>
  );
}
