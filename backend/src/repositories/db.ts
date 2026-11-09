// One MongoClient per Lambda container, opened on the first request and reused by every request after it.
import { MongoClient, type Db } from 'mongodb';
import { forgetParameter, getSecureParameter } from '../lib/ssm';
import { ensureIndexes } from './indexes';

let dbPromise: Promise<Db> | undefined;
let client: MongoClient | undefined;

// MONGODB_URI wins when set (tests, scripts, a laptop). On Lambda only MONGODB_URI_PARAM is set,
// and the URI comes from that SSM parameter.
async function mongoUri(): Promise<string> {
  if (process.env.MONGODB_URI) return process.env.MONGODB_URI;
  const param = process.env.MONGODB_URI_PARAM;
  if (!param) throw new Error('Missing environment variable MONGODB_URI or MONGODB_URI_PARAM');
  return getSecureParameter(param);
}

async function connect(): Promise<Db> {
  client = new MongoClient(await mongoUri(), {
    // A container serves one request at a time, so two sockets are plenty. Small pools keep
    // containers x pool size well under the Atlas M0 limit of 500 connections.
    maxPoolSize: 2,
    serverSelectionTimeoutMS: 5_000,
    appName: 'netzero-api',
  });
  await client.connect();
  const db = client.db(process.env.MONGODB_DB ?? 'netzero');
  await ensureIndexes(db);
  return db;
}

/**
 * The database, connecting on first use. A failed connect is forgotten so the next request tries
 * again, and the cached URI is dropped too in case it was rotated.
 */
export function getDb(): Promise<Db> {
  dbPromise ??= connect().catch((err: unknown) => {
    dbPromise = undefined;
    if (process.env.MONGODB_URI_PARAM) forgetParameter(process.env.MONGODB_URI_PARAM);
    throw err;
  });
  return dbPromise;
}

/** Closes the client. Tests and scripts call this; Lambda never does. */
export async function closeDb(): Promise<void> {
  await client?.close();
  client = undefined;
  dbPromise = undefined;
}
