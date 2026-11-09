// The public health check. It pings MongoDB through the cached client, so a 200 also proves the
// function can reach Atlas.
import { withPublicHandler } from '../lib/http';
import { getDb } from '../repositories/db';

/** GET /health: no token needed. Reports how long the ping took and which stage answered. */
export const handler = withPublicHandler(async () => {
  const started = Date.now();
  const db = await getDb();
  await db.command({ ping: 1 });
  const mongoMs = Date.now() - started;
  return { status: 200, body: { ok: true, mongoMs, stage: process.env.STAGE ?? 'local' } };
});
