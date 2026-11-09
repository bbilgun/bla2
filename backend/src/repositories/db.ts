import { MongoClient, type Db } from 'mongodb';
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

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

async function connect(): Promise<Db> {
  client = new MongoClient(requireEnv('MONGODB_URI'), {
    maxPoolSize: 5,
    serverSelectionTimeoutMS: 5_000,
    appName: 'netzero-api',
  });
  await client.connect();
  const db = client.db(process.env.MONGODB_DB ?? 'netzero');
  await ensureIndexes(db);
  return db;
}

export function getDb(): Promise<Db> {
  // If the first connect fails, forget the rejected promise so the next request retries.
  dbPromise ??= connect().catch((err: unknown) => {
    dbPromise = undefined;
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
