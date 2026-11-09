import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { handler, routes } from '../../src/handlers/api';
import { call, useTestDb } from './helpers';

useTestDb();

/** The httpApi events in serverless.yml, read as text (no YAML parser needed for these one-liners). */
function deployedRoutes() {
  const yml = readFileSync(new URL('../../serverless.yml', import.meta.url), 'utf8');
  // path is either quoted ('/groups/{groupId}') or bare (/health)
  const re = /- httpApi: \{ method: (\w+), path: (?:'([^']+)'|([^,\s}]+))(?:, authorizer: \{ name: (\w+) \})? \}/g;
  return [...yml.matchAll(re)].map((m) => ({ key: `${m[1]} ${m[2] ?? m[3]}`, authorizer: m[4] ?? null }));
}

describe('the single API Lambda', () => {
  it('has a handler for exactly the routes API Gateway sends it', () => {
    const deployed = deployedRoutes().map((r) => r.key);
    expect(deployed.length).toBeGreaterThan(20);
    expect(new Set(deployed).size).toBe(deployed.length);
    expect(Object.keys(routes).sort()).toEqual([...deployed].sort());
  });

  it('only /health and the guest bill page are public; everything else needs the Cognito JWT', () => {
    const publicRoutes = deployedRoutes()
      .filter((r) => r.authorizer === null)
      .map((r) => r.key);
    expect(publicRoutes.sort()).toEqual(
      ['GET /health', 'GET /b/{token}', 'GET /b/{token}/data', 'POST /b/{token}/guests', 'PUT /b/{token}/guests/{guestId}'].sort(),
    );
    for (const r of deployedRoutes().filter((x) => x.authorizer !== null)) expect(r.authorizer).toBe('cognito');
  });

  it('dispatches by routeKey, and an unknown routeKey is a 404', async () => {
    const health = await call(handler as never, { as: null, method: 'GET', path: '/health' });
    expect(health.status).toBe(200);
    expect(health.body.ok).toBe(true);

    const me = await call(handler as never, { method: 'GET', path: '/me' });
    expect(me.status).toBe(200);
    expect(me.body.email).toBe('alice@example.com');

    const unknown = await call(handler as never, { method: 'GET', path: '/nope' });
    expect(unknown.status).toBe(404);
    expect(unknown.body.error.code).toBe('ROUTE_NOT_FOUND');
  });
});
