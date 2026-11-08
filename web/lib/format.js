// Display helpers (server and client).
const inrFmt = new Intl.NumberFormat('en-IN', { maximumFractionDigits: 0 });
export const inr = (n) => (n === null || n === undefined ? '-' : `Rs ${inrFmt.format(Number(n))}`);
export const num = (n, d = 0) =>
  (n === null || n === undefined ? '-' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: d, minimumFractionDigits: d }));
