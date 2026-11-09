/**
 * The one error type the API knows how to turn into an HTTP response.
 * `code` is stable and machine-readable (the app switches on it); `message` is for humans.
 */
export class AppError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'AppError';
  }
}

export const badRequest = (code: string, message: string, details?: unknown) =>
  new AppError(400, code, message, details);

export const forbidden = (code: string, message: string) => new AppError(403, code, message);

export const notFound = (code: string, message: string) => new AppError(404, code, message);

export const conflict = (code: string, message: string, details?: unknown) => new AppError(409, code, message, details);

export const gone = (code: string, message: string) => new AppError(410, code, message);

export const unprocessable = (code: string, message: string) => new AppError(422, code, message);
