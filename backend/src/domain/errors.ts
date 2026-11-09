// The one error type the API turns into an HTTP response, plus a helper per status code.
// lib/http.ts catches these and sends `{ error: { code, message, details? } }`.

/**
 * An error with an HTTP status and a stable `code` the app switches on. `message` is for people.
 * `details`, when present, is sent with the response as structured data.
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

/** 400: the request is malformed or breaks a rule about its own content. */
export function badRequest(code: string, message: string, details?: unknown): AppError {
  return new AppError(400, code, message, details);
}

/** 403: the caller can see the thing but isn't allowed to do this to it. */
export function forbidden(code: string, message: string): AppError {
  return new AppError(403, code, message);
}

/** 404: it doesn't exist, or the caller isn't allowed to know it exists. */
export function notFound(code: string, message: string): AppError {
  return new AppError(404, code, message);
}

/** 409: the request is fine but the current state doesn't allow it, such as a balance that isn't zero. */
export function conflict(code: string, message: string, details?: unknown): AppError {
  return new AppError(409, code, message, details);
}

/** 410: it existed but has expired. */
export function gone(code: string, message: string): AppError {
  return new AppError(410, code, message);
}

/** 422: the request contradicts an earlier one, such as a reused idempotency key. */
export function unprocessable(code: string, message: string): AppError {
  return new AppError(422, code, message);
}
