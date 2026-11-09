// Keeps the router table in src/handlers/api.ts and the routes in serverless.yml in step.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { handler, routes } from '../../src/handlers/api';
import { call, useTestDb } from './helpers';

useTestDb();

const serverlessYml = () => readFileSync(new URL('../../serverless.yml', import.meta.url), 'utf8');

// The httpApi events in serverless.yml. They're one-liners, so a regex does without a YAML parser.
// A path is either quoted ('/groups/{groupId}') or bare (/health).
function deployedRoutes() {
  const re = /- httpApi: \{ method: (\w+), path: (?:'([^']+)'|([^,\s}]+))(?:, authorizer: \{ name: (\w+) \})? \}/g;
  return [...serverlessYml().matchAll(re)].map((m) => ({ key: `${m[1]} ${m[2] ?? m[3]}`, authorizer: m[4] ?? null }));
}

const publicRouteKeys = () =>
  deployedRoutes()
    .filter((route) => route.authorizer === null)
    .map((route) => route.key);

describe('the single API Lambda', () => {
  it('has a handler for exactly the routes API Gateway sends it', () => {
    const deployed = deployedRoutes().map((route) => route.key);

    expect(deployed.length).toBeGreaterThan(20);
    expect(new Set(deployed).size).toBe(deployed.length);
    expect(Object.keys(routes).sort()).toEqual([...deployed].sort());
  });

  it('keeps only /health and the guest page public', () => {
    expect(publicRouteKeys().sort()).toEqual(
      ['GET /health', 'GET /b/{token}', 'GET /b/{token}/data', 'POST /b/{token}/guests', 'PUT /b/{token}/guests/{guestId}'].sort(),
    );
    for (const route of deployedRoutes().filter((r) => r.authorizer !== null)) {
      expect(route.authorizer).toBe('cognito');
    }
  });

  it('throttles every public route more tightly, naming only real routes', () => {
    const yml = serverlessYml();
    const start = yml.indexOf('RouteSettings:');
    const block = yml.slice(start, yml.indexOf('DependsOn:', start));

    const throttled = [...block.matchAll(/'([A-Z]+ \/[^']*)':/g)].map((m) => m[1]!);

    expect(throttled.sort()).toEqual(publicRouteKeys().sort());
    for (const key of throttled) expect(Object.keys(routes)).toContain(key);
  });

  it('adds members only through invites', () => {
    expect(Object.keys(routes)).not.toContain('POST /groups/{groupId}/members');
    expect(Object.keys(routes)).toContain('POST /groups/{groupId}/invites/{inviteId}/accept');
  });

  it('dispatches by routeKey and returns 404 for an unknown one', async () => {
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
