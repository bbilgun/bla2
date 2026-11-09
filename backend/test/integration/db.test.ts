// How the database connection finds its URI. On Lambda only MONGODB_URI_PARAM is set, and the URI comes
// from SSM once per container. lib/ssm is mocked here; the mongod is real.
import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, describe, expect, inject, it, vi } from 'vitest';
import { forgetParameter, getSecureParameter } from '../../src/lib/ssm';
import { closeDb, getDb } from '../../src/repositories/db';

vi.mock('../../src/lib/ssm', () => ({ getSecureParameter: vi.fn(), forgetParameter: vi.fn() }));

const PARAM = '/netzero/test/mongodb-uri';
const saved = { uri: process.env.MONGODB_URI, param: process.env.MONGODB_URI_PARAM };

beforeAll(() => {
  delete process.env.MONGODB_URI;
  process.env.MONGODB_DB = `test_${randomUUID().replaceAll('-', '').slice(0, 12)}`;
});
afterEach(async () => {
  await closeDb();
  vi.mocked(getSecureParameter).mockReset();
  vi.mocked(forgetParameter).mockReset();
});
afterAll(() => {
  if (saved.uri === undefined) delete process.env.MONGODB_URI;
  else process.env.MONGODB_URI = saved.uri;
  if (saved.param === undefined) delete process.env.MONGODB_URI_PARAM;
  else process.env.MONGODB_URI_PARAM = saved.param;
});

describe('connecting with the URI from SSM', () => {
  it('reads the parameter once and reuses the connection', async () => {
    process.env.MONGODB_URI_PARAM = PARAM;
    vi.mocked(getSecureParameter).mockResolvedValue(inject('mongoUri'));

    const db = await getDb();
    await db.command({ ping: 1 });
    await getDb();

    expect(getSecureParameter).toHaveBeenCalledExactlyOnceWith(PARAM);
    await db.dropDatabase();
  });

  it('forgets the cached URI after a failed connect and retries', async () => {
    process.env.MONGODB_URI_PARAM = PARAM;
    vi.mocked(getSecureParameter).mockResolvedValueOnce('not-a-mongodb-uri').mockResolvedValueOnce(inject('mongoUri'));

    await expect(getDb()).rejects.toThrow();
    expect(forgetParameter).toHaveBeenCalledWith(PARAM);

    await expect(getDb()).resolves.toBeDefined();
    expect(getSecureParameter).toHaveBeenCalledTimes(2);
  });

  it('fails clearly when neither variable is set', async () => {
    delete process.env.MONGODB_URI_PARAM;

    await expect(getDb()).rejects.toThrow('MONGODB_URI');
  });

  it('prefers MONGODB_URI over the SSM parameter', async () => {
    process.env.MONGODB_URI = inject('mongoUri');
    process.env.MONGODB_URI_PARAM = PARAM;

    await expect(getDb()).resolves.toBeDefined();
    expect(getSecureParameter).not.toHaveBeenCalled();

    delete process.env.MONGODB_URI;
  });
});
