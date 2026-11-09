// Turns API Gateway events into a small Request object and our Response back into a Lambda result.
// Every route goes through withHandler or withPublicHandler, which also log the request and map errors.
import type {
  APIGatewayProxyEventV2,
  APIGatewayProxyEventV2WithJWTAuthorizer,
  APIGatewayProxyStructuredResultV2,
  Context,
} from 'aws-lambda';
import { ZodError } from 'zod';
import { AppError } from '../domain/errors';
import { logger, type Logger } from './logger';

/** Who is calling. Built only from the verified JWT claims, never from the request body. */
export interface Caller {
  /** The Cognito `sub`. Every user-owned document is keyed on it. */
  userId: string;
  /** Lower-cased. Empty when the token has no email. */
  email: string;
  name: string;
  /** Cognito has confirmed the caller owns `email`. Invites are only ever matched against a verified email. */
  emailVerified: boolean;
}

/** The parts of an API Gateway event a service needs. */
export interface Request {
  params: Record<string, string | undefined>;
  query: Record<string, string | undefined>;
  /** Parsed JSON body, or undefined when there is none. Validate it with a DTO before use. */
  body: unknown;
  /** The body exactly as sent. Idempotent requests are fingerprinted from it. */
  rawBody: string;
  method: string;
  path: string;
  /** The API's own domain, for building share links. */
  host: string;
  /** Looks up a request header. Names are case-insensitive. */
  header(name: string): string | undefined;
  /** A logger already tagged with the request and route. */
  log: Logger;
}

/** A request on a route behind the Cognito authorizer. */
export interface AuthedRequest extends Request {
  caller: Caller;
}

/** What a service returns. `body` is sent as JSON unless `text` is set. */
export interface Response {
  status: number;
  body?: unknown;
  /** Sent as-is in place of a JSON body. Used for the guest web page; set content-type in `headers`. */
  text?: string;
  headers?: Record<string, string>;
}

type LambdaResult = APIGatewayProxyStructuredResultV2;

/** A JSON Lambda result. An undefined body is sent as an empty string. */
export function json(status: number, body: unknown, headers: Record<string, string> = {}): LambdaResult {
  return {
    statusCode: status,
    headers: { 'content-type': 'application/json', ...headers },
    body: body === undefined ? '' : JSON.stringify(body),
  };
}

function callerFrom(event: APIGatewayProxyEventV2WithJWTAuthorizer): Caller {
  const claims = event.requestContext?.authorizer?.jwt?.claims ?? {};
  const sub = claims.sub;
  // Access tokens from our pool pass the API Gateway authorizer too, but only ID tokens carry email and name.
  if (typeof sub !== 'string' || sub.length === 0 || claims.token_use !== 'id') {
    throw new AppError(401, 'UNAUTHORIZED', 'Missing or invalid token');
  }

  let email = '';
  if (typeof claims.email === 'string') {
    email = claims.email.trim().toLowerCase();
  }

  let name = typeof claims.name === 'string' ? claims.name.trim() : '';
  if (!name) {
    name = email.split('@')[0] || 'Member';
  }

  // API Gateway passes claims as strings ("true"); a direct invoke may pass real booleans.
  const verifiedClaim = claims.email_verified as unknown;
  const emailVerified = email.length > 0 && (verifiedClaim === true || verifiedClaim === 'true');

  return { userId: sub, email, name, emailVerified };
}

function decodeBody(event: APIGatewayProxyEventV2): string {
  if (!event.body) return '';
  if (event.isBase64Encoded) return Buffer.from(event.body, 'base64').toString('utf8');
  return event.body;
}

function buildRequest(event: APIGatewayProxyEventV2, log: Logger): Request {
  const rawBody = decodeBody(event);
  let body: unknown;
  if (rawBody) {
    try {
      body = JSON.parse(rawBody);
    } catch {
      throw new AppError(400, 'INVALID_JSON', 'Request body is not valid JSON');
    }
  }

  // API Gateway lower-cases header names.
  const headers = event.headers ?? {};
  return {
    params: event.pathParameters ?? {},
    query: event.queryStringParameters ?? {},
    body,
    rawBody,
    method: event.requestContext?.http?.method ?? 'GET',
    path: event.rawPath ?? '/',
    host: event.requestContext?.domainName ?? event.headers?.host ?? 'localhost',
    header: (name) => headers[name.toLowerCase()],
    log,
  };
}

function toErrorResult(err: unknown, log: Logger): LambdaResult {
  if (err instanceof AppError) {
    const level = err.status >= 500 ? 'error' : 'info';
    log[level]('request.failed', { status: err.status, code: err.code, message: err.message });
    const error: Record<string, unknown> = { code: err.code, message: err.message };
    if (err.details !== undefined) error.details = err.details;
    return json(err.status, { error });
  }

  if (err instanceof ZodError) {
    const details = err.issues.map((issue) => ({ path: issue.path.join('.'), message: issue.message }));
    log.info('request.failed', { status: 400, code: 'VALIDATION_ERROR', details });
    return json(400, { error: { code: 'VALIDATION_ERROR', message: 'Request is invalid', details } });
  }

  log.error('request.crashed', { err });
  return json(500, { error: { code: 'INTERNAL', message: 'Something went wrong' } });
}

/** The part both wrappers share: logging, timing, turning a Response into a Lambda result, and errors. */
function wrap<E extends APIGatewayProxyEventV2>(run: (event: E, log: Logger) => Promise<Response>) {
  return async (event: E, context: Context): Promise<LambdaResult> => {
    // The cached MongoClient keeps sockets open; don't make Lambda wait for them to close.
    context.callbackWaitsForEmptyEventLoop = false;
    const log = logger.child({
      requestId: context.awsRequestId,
      apiRequestId: event.requestContext?.requestId,
      route: event.routeKey,
    });
    const started = Date.now();

    try {
      const res = await run(event, log);
      log.info('request.ok', { status: res.status, ms: Date.now() - started });
      if (res.text !== undefined) {
        return { statusCode: res.status, headers: res.headers ?? {}, body: res.text };
      }
      return json(res.status, res.body, res.headers);
    } catch (err) {
      return toErrorResult(err, log);
    }
  };
}

/** Wraps a route behind the Cognito authorizer. The caller comes only from the token's claims. */
export function withHandler(fn: (req: AuthedRequest) => Promise<Response>) {
  return wrap<APIGatewayProxyEventV2WithJWTAuthorizer>(async (event, log) => {
    const caller = callerFrom(event);
    const req = buildRequest(event, log.child({ userId: caller.userId }));
    return fn({ ...req, caller });
  });
}

/** Wraps a route with no authorizer: the health check and the guest bill page. */
export function withPublicHandler(fn: (req: Request) => Promise<Response>) {
  return wrap<APIGatewayProxyEventV2>(async (event, log) => fn(buildRequest(event, log)));
}

/** A path parameter. Throws 400 MISSING_PARAM when it's absent, which API Gateway normally prevents. */
export function requireParam(req: Request, name: string): string {
  const value = req.params[name];
  if (!value) throw new AppError(400, 'MISSING_PARAM', `Missing path parameter: ${name}`);
  return value;
}
