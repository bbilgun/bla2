import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2, Context } from 'aws-lambda';
import { json } from '../lib/http';
import * as balances from './balances';
import * as billPage from './billPage';
import * as bills from './bills';
import * as expenses from './expenses';
import * as groups from './groups';
import * as health from './health';
import * as me from './me';
import * as receipts from './receipts';
import * as settlements from './settlements';

type RouteHandler = (event: never, context: Context) => Promise<APIGatewayProxyStructuredResultV2>;

/**
 * The single Lambda behind the whole API.
 *
 * API Gateway does the real routing and the Cognito JWT check per route (serverless.yml); by the time
 * an event gets here it carries the matched routeKey, e.g. "GET /groups/{groupId}". This table maps
 * that to the route's handler, which still does all its own parsing and error handling.
 *
 * Why one function: with one function per route, every route had its own cold start (~1 s each) and its
 * own MongoDB connection pool, so a fresh session paid that second again on every screen.
 * test/integration/router.test.ts checks this table against serverless.yml.
 */
export const routes: Record<string, RouteHandler> = {
  'GET /health': health.handler,
  'GET /me': me.handler,
  'POST /groups': groups.create,
  'GET /groups': groups.list,
  'GET /groups/{groupId}': groups.get,
  'POST /groups/{groupId}/members': groups.addMember,
  'POST /groups/{groupId}/expenses': expenses.create,
  'GET /groups/{groupId}/expenses': expenses.list,
  'POST /groups/{groupId}/settlements': settlements.create,
  'GET /groups/{groupId}/settlements': settlements.list,
  'GET /groups/{groupId}/balances': balances.handler,
  'POST /groups/{groupId}/expenses/{expenseId}/receipt-url': receipts.uploadUrl,
  'GET /groups/{groupId}/expenses/{expenseId}/receipt-url': receipts.viewUrl,
  'POST /bills': bills.create,
  'GET /bills': bills.list,
  'GET /bills/{billId}': bills.get,
  'PUT /bills/{billId}': bills.update,
  'POST /bills/{billId}/status': bills.setStatus,
  'PUT /bills/{billId}/guests/{guestId}': bills.updateGuest,
  'DELETE /bills/{billId}/guests/{guestId}': bills.removeGuest,
  'POST /me/pay-qr-url': bills.payQrUploadUrl,
  'GET /b/{token}': billPage.page,
  'GET /b/{token}/data': billPage.data,
  'POST /b/{token}/guests': billPage.join,
  'PUT /b/{token}/guests/{guestId}': billPage.updateGuest,
};

export async function handler(event: APIGatewayProxyEventV2, context: Context): Promise<APIGatewayProxyStructuredResultV2> {
  const route = routes[event.routeKey];
  if (!route) return json(404, { error: { code: 'ROUTE_NOT_FOUND', message: `No route for ${event.routeKey}` } });
  return route(event as never, context);
}
