import { MongoClient, type Db } from 'mongodb';
import { forgetParameter, getSecureParameter } from '../lib/ssm';
import { ensureIndexes } from './indexes';

/**
 * One MongoClient per Lambda container.
 *
 * Module scope runs once when the container starts; the handler runs on every request.
 * Caching the connection promise here means a warm request reuses the open socket pool
 * instead of paying a TLS + auth handshake to Atlas each time (and exhausting M0's connection limit).
 */
let dbPromise: Promise<Db> | undefined;
let client: MongoClient | undefined;

/**
 * MONGODB_URI wins when set (tests, scripts, a laptop). On Lambda only MONGODB_URI_PARAM is set, and
 * the URI is read from that SSM SecureString once per container (lib/ssm caches it).
 */
async function mongoUri(): Promise<string> {
  if (process.env.MONGODB_URI) return process.env.MONGODB_URI;
  const param = process.env.MONGODB_URI_PARAM;
  if (!param) throw new Error('Missing environment variable MONGODB_URI or MONGODB_URI_PARAM');
  return getSecureParameter(param);
}

async function connect(): Promise<Db> {
  client = new MongoClient(await mongoUri(), {
    // A Lambda container handles one request at a time; two sockets cover the occasional parallel
    // query. Small pools keep (containers x pool) well under Atlas M0's 500-connection limit.
    maxPoolSize: 2,
    serverSelectionTimeoutMS: 5_000,
    appName: 'netzero-api',
  });
  await client.connect();
  const db = client.db(process.env.MONGODB_DB ?? 'netzero');
  await ensureIndexes(db);
  return db;
}

export function getDb(): Promise<Db> {
  // If the first connect fails, forget the rejected promise so the next request retries,
  // and re-read the URI too in case it was rotated.
  dbPromise ??= connect().catch((err: unknown) => {
    dbPromise = undefined;
    if (process.env.MONGODB_URI_PARAM) forgetParameter(process.env.MONGODB_URI_PARAM);
    throw err;
  });
  return dbPromise;
}

/** Used by tests and scripts; Lambda never closes the client. */
export async function closeDb(): Promise<void> {
  await client?.close();
  client = undefined;
  dbPromise = undefined;
}
