import { withPublicHandler } from '../lib/http';
import { getDb } from '../repositories/db';

/** GET /health — public. Pings Atlas through the cached client, so it also proves network access works. */
export const handler = withPublicHandler(async () => {
  const started = Date.now();
  const db = await getDb();
  await db.command({ ping: 1 });
  return { status: 200, body: { ok: true, mongoMs: Date.now() - started, stage: process.env.STAGE ?? 'local' } };
});
