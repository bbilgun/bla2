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
  userId: string;
  email: string;
  name: string;
  /** Cognito has confirmed the caller owns `email`. Invites are only ever matched against a verified email. */
  emailVerified: boolean;
}

export interface Request {
  params: Record<string, string | undefined>;
  query: Record<string, string | undefined>;
  /** Parsed JSON body, or undefined when there is none. Validate it with a Zod DTO before use. */
  body: unknown;
  /** Exact request body as sent, used to fingerprint idempotent requests. */
  rawBody: string;
  method: string;
  path: string;
  /** The API's own domain ("abc123.execute-api.ap-northeast-1.amazonaws.com"), for building share links. */
  host: string;
  header(name: string): string | undefined;
  log: Logger;
}

export interface AuthedRequest extends Request {
  caller: Caller;
}

export interface Response {
  status: number;
  body?: unknown;
  /** Sent as-is instead of JSON (the guest web page). Set content-type in `headers`. */
  text?: string;
  headers?: Record<string, string>;
}

type LambdaResult = APIGatewayProxyStructuredResultV2;

export function json(status: number, body: unknown, headers: Record<string, string> = {}): LambdaResult {
  return {
    statusCode: status,
    headers: { 'content-type': 'application/json', ...headers },
    body: body === undefined ? '' : JSON.stringify(body),
  };
}

/**
 * The API Gateway JWT authorizer accepts any token from our user pool for our client, and Cognito access
 * tokens pass that check too (their `client_id` matches). Only ID tokens carry the email and name we
 * rely on, so anything else is rejected here. API Gateway passes claims as strings ("true"), a direct
 * invoke may pass real booleans: accept both.
 */
function callerFrom(event: APIGatewayProxyEventV2WithJWTAuthorizer): Caller {
  const claims = event.requestContext?.authorizer?.jwt?.claims ?? {};
  const sub = claims.sub;
  if (typeof sub !== 'string' || sub.length === 0 || claims.token_use !== 'id') {
    throw new AppError(401, 'UNAUTHORIZED', 'Missing or invalid token');
  }
  const email = typeof claims.email === 'string' ? claims.email.trim().toLowerCase() : '';
  const name = typeof claims.name === 'string' && claims.name.trim() ? claims.name.trim() : email.split('@')[0] || 'Member';
  const verifiedClaim = claims.email_verified as unknown;
  const emailVerified = email.length > 0 && (verifiedClaim === true || verifiedClaim === 'true');
  return { userId: sub, email, name, emailVerified };
}

function decodeBody(event: APIGatewayProxyEventV2): string {
  if (!event.body) return '';
  return event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body;
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
    const details = err.issues.map((i) => ({ path: i.path.join('.'), message: i.message }));
    log.info('request.failed', { status: 400, code: 'VALIDATION_ERROR', details });
    return json(400, { error: { code: 'VALIDATION_ERROR', message: 'Request is invalid', details } });
  }
  log.error('request.crashed', { err });
  return json(500, { error: { code: 'INTERNAL', message: 'Something went wrong' } });
}

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
      if (res.text !== undefined) return { statusCode: res.status, headers: res.headers ?? {}, body: res.text };
      return json(res.status, res.body, res.headers);
    } catch (err) {
      return toErrorResult(err, log);
    }
  };
}

/** Every authenticated route goes through this. Identity comes only from `claims.sub`. */
export function withHandler(fn: (req: AuthedRequest) => Promise<Response>) {
  return wrap<APIGatewayProxyEventV2WithJWTAuthorizer>(async (event, log) => {
    const caller = callerFrom(event);
    const req = buildRequest(event, log.child({ userId: caller.userId }));
    return fn({ ...req, caller });
  });
}

/** Routes with no authorizer: the health check and the guest bill page, which anyone with the link can open. */
export function withPublicHandler(fn: (req: Request) => Promise<Response>) {
  return wrap<APIGatewayProxyEventV2>(async (event, log) => fn(buildRequest(event, log)));
}

export function requireParam(req: Request, name: string): string {
  const value = req.params[name];
  if (!value) throw new AppError(400, 'MISSING_PARAM', `Missing path parameter: ${name}`);
  return value;
}
