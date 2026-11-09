import { randomUUID } from 'node:crypto';
import type { APIGatewayProxyStructuredResultV2, Context } from 'aws-lambda';
import { afterAll, beforeAll, beforeEach, inject } from 'vitest';
import { closeDb, getDb } from '../../src/repositories/db';

/**
 * Integration tests call the real Lambda handlers with a fake API Gateway event,
 * so they exercise withHandler -> service -> repository -> MongoDB end to end.
 * Mongo is a real mongod (mongodb-memory-server), never a mock: aggregation bugs live in the pipeline.
 */
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

export interface TestUser {
  sub: string;
  email: string;
  name: string;
}

export const alice: TestUser = { sub: 'sub-alice', email: 'alice@example.com', name: 'Alice' };
export const bob: TestUser = { sub: 'sub-bob', email: 'bob@example.com', name: 'Bob' };
export const carol: TestUser = { sub: 'sub-carol', email: 'carol@example.com', name: 'Carol' };
export const mallory: TestUser = { sub: 'sub-mallory', email: 'mallory@example.com', name: 'Mallory' };

interface CallOptions {
  as?: TestUser | null;
  method?: string;
  path?: string;
  params?: Record<string, string>;
  query?: Record<string, string>;
  body?: unknown;
  headers?: Record<string, string>;
}

type Handler = (event: never, context: Context) => Promise<APIGatewayProxyStructuredResultV2>;

// Test responses are asserted field by field; `any` keeps those assertions short.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export interface CallResult<T = any> {
  status: number;
  body: T;
  headers: Record<string, string | number | boolean>;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function call<T = any>(handler: Handler, opts: CallOptions = {}): Promise<CallResult<T>> {
  const user = opts.as === undefined ? alice : opts.as;
  const event = {
    routeKey: `${opts.method ?? 'GET'} ${opts.path ?? '/'}`,
    rawPath: opts.path ?? '/',
    headers: Object.fromEntries(Object.entries(opts.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v])),
    queryStringParameters: opts.query,
    pathParameters: opts.params,
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    isBase64Encoded: false,
    requestContext: {
      requestId: randomUUID(),
      http: { method: opts.method ?? 'GET' },
      authorizer: user ? { jwt: { claims: { sub: user.sub, email: user.email, name: user.name }, scopes: [] } } : undefined,
    },
  };
  const context = { awsRequestId: randomUUID(), callbackWaitsForEmptyEventLoop: true } as unknown as Context;
  const res = await handler(event as never, context);
  return {
    status: res.statusCode ?? 0,
    body: !res.body ? undefined : String(res.headers?.['content-type']).includes('json') ? JSON.parse(res.body) : res.body,
    headers: res.headers ?? {},
  };
}
