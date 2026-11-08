// An error with an HTTP status, so API routes can answer 400 / 403 / 404 cleanly.
export class AppError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// MySQL privilege errors (1142 table, 1143 column, 1370 routine) mean the
// DATABASE refused the role: report them as 403 "access denied".
export function fromDbError(err) {
  if (err instanceof AppError) return err;
  if ([1142, 1143, 1370].includes(err?.errno)) {
    return new AppError(403, `Access denied by MySQL: ${err.sqlMessage}`);
  }
  if (err?.sqlState === '45000') return new AppError(400, err.sqlMessage);   // our SIGNALs
  if (err?.code === 121) return new AppError(400, 'Document failed MongoDB schema validation');
  return err;
}
