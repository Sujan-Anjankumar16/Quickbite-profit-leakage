import './globals.css';
import Nav from '@/components/Nav.js';
import { getSession } from '@/lib/session.js';

export const metadata = { title: 'QuickBite Profit Leakage Analyzer' };
export const dynamic = 'force-dynamic';      // every page depends on the session cookie

export default async function RootLayout({ children }) {
  const user = await getSession();
  return (
    <html lang="en">
      <body>
        {user && <Nav user={user} />}
        <main>{children}</main>
      </body>
    </html>
  );
}
