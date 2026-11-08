export default function AccessDenied({ user, need }) {
  return (
    <div className="alert err">
      <strong>Access denied.</strong> This page needs the {need} role; you are logged in as {user.role}.
    </div>
  );
}
