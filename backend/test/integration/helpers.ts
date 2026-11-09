// Shared setup for the integration tests. They call the real Lambda handlers with a fake API Gateway
// event, so each test runs withHandler, the service, the repository and a real mongod end to end.
// Calls that would reach AWS (S3 HEAD and DELETE, SSM, Cognito) are vi.mock'ed in the files that need them.
import { randomUUID } from 'node:crypto';
import type { APIGatewayProxyStructuredResultV2, Context } from 'aws-lambda';
import { afterAll, beforeAll, beforeEach, expect, inject } from 'vitest';
import * as groups from '../../src/handlers/groups';
import { closeDb, getDb } from '../../src/repositories/db';

/** Points the app at a fresh database for this file and empties it before every test. */
export function useTestDb() {
  beforeAll(() => {
    process.env.MONGODB_URI = inject('mongoUri');
    process.env.MONGODB_DB = `test_${randomUUID().replaceAll('-', '').slice(0, 12)}`;
  });
  beforeEach(async () => {
    const db = await getDb();
    const collections = await db.collections();
    await Promise.all(collections.map((c) => c.deleteMany({})));
  });
  afterAll(async () => {
    const db = await getDb();
    await db.dropDatabase();
    await closeDb();
  });
}

/** Fake AWS settings. Signing a URL happens locally, so fake credentials are enough and nothing reaches AWS. */
export function useFakeAwsEnv() {
  beforeAll(() => {
    process.env.RECEIPTS_BUCKET = 'netzero-test-receipts';
    process.env.AWS_REGION = 'ap-northeast-1';
    process.env.AWS_ACCESS_KEY_ID = 'AKIATESTTESTTESTTEST';
    process.env.AWS_SECRET_ACCESS_KEY = 'test-secret';
    delete process.env.AWS_PROFILE;
    delete process.env.AWS_SESSION_TOKEN;
  });
}

/** A signed-in user, as far as the token claims go. */
export interface TestUser {
  sub: string;
  email: string;
  name: string;
  /** Defaults to true, like every account that finished Cognito sign-up. */
  emailVerified?: boolean;
}

export const alice: TestUser = { sub: 'sub-alice', email: 'alice@example.com', name: 'Alice' };
export const bob: TestUser = { sub: 'sub-bob', email: 'bob@example.com', name: 'Bob' };
export const carol: TestUser = { sub: 'sub-carol', email: 'carol@example.com', name: 'Carol' };
export const mallory: TestUser = { sub: 'sub-mallory', email: 'mallory@example.com', name: 'Mallory' };

interface CallOptions {
  /** Who is calling. Defaults to alice; null sends no claims at all, like a public route. */
  as?: TestUser | null;
  method?: string;
  path?: string;
  params?: Record<string, string>;
  query?: Record<string, string>;
  body?: unknown;
  headers?: Record<string, string>;
  /** Merged over the user's claims. `undefined` removes a claim. */
  claims?: Record<string, unknown>;
  /** Sends the body base64-encoded, as API Gateway does for some content types. */
  base64?: boolean;
}

type Handler = (event: never, context: Context) => Promise<APIGatewayProxyStructuredResultV2>;

// Test responses are asserted field by field, and `any` keeps those assertions short.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export interface CallResult<T = any> {
  status: number;
  body: T;
  headers: Record<string, string | number | boolean>;
}

// What API Gateway's JWT authorizer passes for a Cognito ID token. It turns booleans into strings.
function claimsFor(user: TestUser, extra: Record<string, unknown> = {}) {
  const claims: Record<string, unknown> = {
    sub: user.sub,
    email: user.email,
    name: user.name,
    email_verified: String(user.emailVerified ?? true),
    token_use: 'id',
    ...extra,
  };
  for (const [key, value] of Object.entries(claims)) {
    if (value === undefined) delete claims[key];
  }
  return claims;
}

/** Calls a handler the way API Gateway would and parses the JSON response. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function call<T = any>(handler: Handler, opts: CallOptions = {}): Promise<CallResult<T>> {
  const user = opts.as === undefined ? alice : opts.as;
  const method = opts.method ?? 'GET';
  const path = opts.path ?? '/';
  const json = opts.body === undefined ? undefined : JSON.stringify(opts.body);
  const body = json !== undefined && opts.base64 ? Buffer.from(json, 'utf8').toString('base64') : json;

  const event = {
    routeKey: `${method} ${path}`,
    rawPath: path,
    headers: Object.fromEntries(Object.entries(opts.headers ?? {}).map(([key, value]) => [key.toLowerCase(), value])),
    queryStringParameters: opts.query,
    pathParameters: opts.params,
    body,
    isBase64Encoded: Boolean(opts.base64),
    requestContext: {
      requestId: randomUUID(),
      domainName: 'api.example',
      http: { method },
      authorizer: user ? { jwt: { claims: claimsFor(user, opts.claims), scopes: [] } } : undefined,
    },
  };
  const context = { awsRequestId: randomUUID(), callbackWaitsForEmptyEventLoop: true } as unknown as Context;

  const res = await handler(event as never, context);

  const isJson = String(res.headers?.['content-type']).includes('json');
  let parsed: unknown;
  if (res.body) parsed = isJson ? JSON.parse(res.body) : res.body;
  return { status: res.statusCode ?? 0, body: parsed as T, headers: res.headers ?? {} };
}

/** `inviter` invites `user` by email and `user` accepts, which is the only way into a group. */
export async function addToGroup(groupId: string, user: TestUser, inviter: TestUser = alice) {
  const invited = await call(groups.invite, { as: inviter, method: 'POST', params: { groupId }, body: { email: user.email } });
  expect(invited.status).toBe(200);
  const invite = invited.body.invites.find((i: { email: string }) => i.email === user.email);

  const accepted = await call(groups.acceptInvite, {
    as: user,
    method: 'POST',
    params: { groupId, inviteId: invite.id },
  });
  expect(accepted.status).toBe(200);
  return accepted.body;
}
