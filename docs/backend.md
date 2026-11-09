# The NetZero backend: a guided tour

This is a tour of `backend/` for someone who has never seen it. It explains how a request travels through
the code, what each folder is for, the handful of ideas the code leans on, and how the main features work
end to end. Setup and deployment live in the root [README](../README.md); this page is about the code.

Keep the code open next to this page. Every file path here is relative to the repository root.

Contents:

1. [The big picture: one request, start to finish](#1-the-big-picture-one-request-start-to-finish)
2. [Folder layout and the rules of each layer](#2-folder-layout-and-the-rules-of-each-layer)
3. [Ideas the code relies on](#3-ideas-the-code-relies-on)
4. [Walkthroughs of the main flows](#4-walkthroughs-of-the-main-flows)
5. [The data model](#5-the-data-model)
6. [serverless.yml, section by section](#6-serverlessyml-section-by-section)
7. [How the tests work, and how to add one](#7-how-the-tests-work-and-how-to-add-one)
8. [A suggested reading order](#8-a-suggested-reading-order)

---

## 1. The big picture: one request, start to finish

The backend is a single AWS Lambda function written in TypeScript, sitting behind API Gateway, talking to
MongoDB Atlas. Users sign in with Amazon Cognito. Photos go straight from the phone to a private S3 bucket.

```
  Phone (Flutter app)                         Guest's browser (no account)
        |  HTTPS, Authorization: Bearer <ID token>     |  HTTPS, /b/{token}...
        v                                              v
  +-------------------------------------------------------------+
  | API Gateway (HTTP API)                                       |
  |   1. matches the route ("GET /groups/{groupId}")             |
  |   2. checks the Cognito JWT, if the route has an authorizer  |
  |   3. applies the route's throttle                            |
  +-------------------------------------------------------------+
        |  one event, with routeKey and the token's claims
        v
  Lambda "api"  (Node 22, one function for every route)
        |
        |  src/handlers/api.ts       handler(): routes[event.routeKey]
        |  src/handlers/groups.ts    get = withHandler(req => getGroup(req, groupId))
        |  src/lib/http.ts           withHandler: caller from claims, parse body, log, map errors
        |  src/services/groups.ts    getGroup(): requireMembership(), then groupJson()
        |  src/repositories/groups.ts findGroupForMember(): one findOne
        |  src/repositories/db.ts    getDb(): the cached MongoClient
        v
  MongoDB Atlas
```

Here's what happens for `GET /groups/{groupId}`, step by step.

1. **API Gateway** matches the URL against the routes declared in `backend/serverless.yml`. This route has
   `authorizer: { name: cognito }`, so API Gateway checks the `Authorization` header before anything of
   ours runs: the signature, that the token came from our user pool, that it's for our app client, and that
   it hasn't expired. A bad token gets a 401 straight from API Gateway and Lambda never runs.
2. **Lambda** receives an event. The interesting parts are `routeKey` (the matched route template, such as
   `"GET /groups/{groupId}"`), `pathParameters` (`{ groupId: "..." }`), the body, and
   `requestContext.authorizer.jwt.claims` (what was inside the token).
3. **`src/handlers/api.ts`** is the function's entry point. It looks the route key up in its `routes` table
   and calls the matching handler. An unknown key gets `404 ROUTE_NOT_FOUND`.
4. **`src/handlers/groups.ts`** has one export per route. Each is a one-liner: it pulls the path parameters
   out with `requireParam` and calls one service function.
5. **`src/lib/http.ts`** is what makes that one-liner work. `withHandler` wraps every signed-in route. It
   builds the `Caller` from the token's claims (and refuses anything that isn't an ID token), decodes and
   parses the JSON body, attaches a logger tagged with the request id and route, runs the service, and turns
   the result or any thrown error into a Lambda response.
6. **`src/services/groups.ts`** holds the rules. `getGroup` calls `requireMembership`, which loads the group
   only if the caller is in it, and returns `{ status: 200, body: groupJson(group) }`.
7. **`src/repositories/groups.ts`** is the only code that queries the `groups` collection.
   `findGroupForMember` is one `findOne` whose filter includes the caller's user id.
8. **`src/repositories/db.ts`** hands out the database. The connection is opened on the first request a
   Lambda container serves and reused by every request after it.

On the way back, `withHandler` logs `request.ok` with the status and duration, sets
`content-type: application/json` and returns. If anything threw, it becomes an error response instead:

| What was thrown                      | Response                                                        |
| ------------------------------------ | --------------------------------------------------------------- |
| `AppError` (from `src/domain/errors.ts`) | its `status` and `{ "error": { "code", "message", "details"? } }` |
| A Zod validation error               | `400 { "error": { "code": "VALIDATION_ERROR", "details": [...] } }` |
| Anything else                        | `500 { "error": { "code": "INTERNAL" } }`, logged as `request.crashed` |

### Cold starts and warm requests

Lambda runs our code in a *container*. The first request a new container serves is a **cold start**: Node
loads the bundle, module-level code runs, and `getDb()` connects to Atlas. That first connect also reads the
MongoDB URI from SSM Parameter Store (`src/lib/ssm.ts`) and makes sure every index exists
(`src/repositories/indexes.ts`). Every later request to the same container is **warm**: the module-level
`dbPromise` already holds a connected client, so the request goes straight to the query.

That's why the whole API is one function. With a function per route, each route had its own containers, so a
user moving between screens kept paying cold starts and opening new connection pools.

### Where errors come from

Every error the app can see has a stable `code`. The app switches on the code, never the message.

| Status | Codes |
| ------ | ----- |
| 400 | `INVALID_JSON`, `VALIDATION_ERROR`, `MISSING_PARAM`, `IDEMPOTENCY_KEY_REQUIRED`, `IDEMPOTENCY_KEY_INVALID`, `INVALID_AMOUNT`, `INVALID_WEIGHT`, `INVALID_PERCENT`, `SPLIT_EMPTY`, `SPLIT_DUPLICATE_USER`, `SPLIT_SUM_MISMATCH`, `SPLIT_PERCENT_MISMATCH`, `PAYER_NOT_MEMBER`, `SPLIT_USER_NOT_MEMBER`, `SETTLEMENT_USER_NOT_MEMBER`, `CANNOT_REMOVE_SELF`, `CANNOT_REMOVE_HOST`, `INVALID_UPLOAD_KEY` |
| 401 | `UNAUTHORIZED` |
| 403 | `NOT_A_PARTY` |
| 404 | `ROUTE_NOT_FOUND`, `GROUP_NOT_FOUND`, `INVITE_NOT_FOUND`, `MEMBER_NOT_FOUND`, `EXPENSE_NOT_FOUND`, `SETTLEMENT_NOT_FOUND`, `RECEIPT_NOT_FOUND`, `BILL_NOT_FOUND`, `GUEST_NOT_FOUND` |
| 409 | `BALANCE_NOT_ZERO`, `BALANCES_NOT_ZERO`, `ALREADY_MEMBER`, `GROUP_FULL`, `EXPENSE_CHANGED`, `UPLOAD_NOT_FOUND`, `BILL_CLOSED`, `BILL_FULL`, `NAME_TAKEN`, `GUEST_REMOVED`, `GUEST_ID_TAKEN` |
| 410 | `BILL_EXPIRED` |
| 422 | `IDEMPOTENCY_KEY_REUSED` |
| 500 | `INTERNAL`, `BALANCES_DO_NOT_SUM_TO_ZERO` |

The full list of routes, with their bodies, is in the API table in the root README.

---

## 2. Folder layout and the rules of each layer

```
backend/
  serverless.yml        what gets deployed: the function, its routes, Cognito, S3, alarms
  package.json          scripts: check (typecheck + lint + test), deploy, seed, ...
  eslint.config.mjs     lint rules, including a ban on parseFloat and Math.round
  tsconfig.json         strict TypeScript, no emit (esbuild bundles at deploy time)
  vitest.config.mts     test runner setup
  scripts/              dev and ops scripts: seed data, get a token, smoke test a stage
  src/
    handlers/           one export per route, each a one-liner
    lib/                HTTP plumbing, logging and the AWS clients
    services/           the business rules
    repositories/       every MongoDB query and update
    aggregations/       MongoDB pipelines that derive data (balances)
    domain/             pure logic: money, splitting, settling up, bill math, errors
    dto/                Zod schemas for every request body and query string
    web/                the guest bill page (HTML and its script)
  test/
    domain/             unit tests for src/domain
    lib/                tests for the AWS wrappers, with the SDK stubbed
    integration/        handlers end to end against a real in-memory MongoDB
    web/                the guest page running in jsdom against the real API
```

A request only ever flows downwards: handlers call services, services call repositories, aggregations and
domain code, and those call MongoDB. Nothing lower down imports anything higher up.

| Layer | Its job | It must not |
| ----- | ------- | ----------- |
| `handlers/` | Map one route to one service call, pulling path parameters out with `requireParam`. `billPage.ts` also builds the guest page's security headers. | Parse bodies, apply rules, or touch MongoDB. The one exception is `health.ts`, which pings the database directly because it has no rules to apply. |
| `services/` | Validate input with a DTO, decide who may do what (membership, ownership, being a party to a payment), apply the business rules, call repositories, and return `{ status, body }`. Throws `AppError` for anything the caller should hear about. | Query collections directly, or know about Lambda events. Every service export has the same shape: `(req, ...pathParams) => Promise<Response>`. |
| `repositories/` | One function per query or atomic update. Rules that must hold *at the moment of the write* go into the update's filter. Returns documents, `null` or a boolean. | Throw HTTP errors or make decisions. A `null` means "the write didn't match"; the service works out why. |
| `aggregations/` | MongoDB pipelines that compute derived data. | Same as repositories. |
| `domain/` | Pure functions: money, splitting, the settle-up suggestion, bill totals, and the `AppError` type. No I/O, no database, no AWS, no clock. | Import from any other layer. |
| `dto/` | Zod schemas. Validation and light normalising only: trimming, lower-casing emails, defaults, turning a cursor into an `ObjectId`. | Contain rules that need data, such as "is this person in the group". |
| `lib/` | Plumbing that knows about HTTP and AWS but nothing about groups or bills. | Contain business rules. |
| `web/` | The static HTML, CSS and browser script of the guest page. | Contain server logic. |

### Every file, in one line each

| File | What it's for |
| ---- | ------------- |
| `backend/serverless.yml` | The deployed stack: one Lambda, its routes and authorizer, IAM, the user pool, the bucket, alarms and throttles. |
| `backend/package.json` | Dependencies and scripts. `npm run check` runs the same typecheck, lint and tests as CI. |
| `backend/eslint.config.mjs` | Lint rules. Bans `parseFloat` and `Math.round`, which are almost always money bugs. |
| `backend/tsconfig.json` | Strict TypeScript settings, including `noUncheckedIndexedAccess`. |
| `backend/vitest.config.mts` | Test discovery, the global mongod setup, silent logs and timeouts. |
| `src/handlers/api.ts` | The Lambda entry point and the route table. |
| `src/handlers/groups.ts` | Routes for groups, members and invites. |
| `src/handlers/expenses.ts` | Routes for a group's expenses. |
| `src/handlers/settlements.ts` | Routes for payments recorded between members. |
| `src/handlers/balances.ts` | The balances route. |
| `src/handlers/receipts.ts` | Routes for receipt photos on expenses. |
| `src/handlers/me.ts` | Routes for the caller's own account: profile, bank QR, deletion. |
| `src/handlers/bills.ts` | The host's routes for QR bills. |
| `src/handlers/billPage.ts` | The public guest routes: the page itself and its JSON endpoints. |
| `src/handlers/health.ts` | The public health check, which pings MongoDB. |
| `src/lib/http.ts` | `withHandler`, `withPublicHandler`, the `Request`, `Caller` and `Response` types, and error mapping. |
| `src/lib/logger.ts` | One-line JSON logs with per-request fields. |
| `src/lib/s3.ts` | Signing upload and view URLs, checking and deleting objects, the bucket's origin for the CSP. |
| `src/lib/ssm.ts` | Reading and caching SecureString parameters from SSM. |
| `src/lib/cognito.ts` | Deleting a Cognito user, for account deletion. |
| `src/services/groups.ts` | Groups, membership, invites, leaving and removing people. Home of `requireMembership`. |
| `src/services/expenses.ts` | Creating, listing, editing and deleting expenses. |
| `src/services/settlements.ts` | Recording, listing and deleting payments between members. |
| `src/services/balances.ts` | The balances screen: nets per person and suggested payments. |
| `src/services/receipts.ts` | Receipt uploads and view URLs. |
| `src/services/account.ts` | `GET /me`, the bank QR upload, and deleting an account. |
| `src/services/bills.ts` | QR bills: the host's routes and the guests' routes. |
| `src/services/idempotency.ts` | `idempotent()`, which makes a create safe to retry. |
| `src/services/uploads.ts` | Shared steps of a two-step image upload: pick a key, check a confirmed key, delete the replaced object. |
| `src/services/users.ts` | `registerCaller`, which keeps the users row and each group's copy of the member's name in step. |
| `src/services/serializers.ts` | Turns documents into the JSON the app sees, and works out every bill total. |
| `src/repositories/documents.ts` | The TypeScript shape of every stored document. |
| `src/repositories/collections.ts` | Typed collection handles, `toObjectId`, `NOT_DELETED`, `insertOnce` and `pageNewestFirst`. |
| `src/repositories/db.ts` | The cached MongoClient and where its URI comes from. |
| `src/repositories/indexes.ts` | Every index, created on each container's first connect. |
| `src/repositories/users.ts` | The users collection. |
| `src/repositories/groups.ts` | The groups collection, with members and invites embedded. |
| `src/repositories/expenses.ts` | The expenses collection, including the compare-and-set edit. |
| `src/repositories/settlements.ts` | The settlements collection. |
| `src/repositories/bills.ts` | The bills collection, with lines and guests embedded. |
| `src/repositories/idempotency.ts` | Claiming and completing idempotency keys. |
| `src/aggregations/balances.ts` | The balances pipeline and `computeBalances`. |
| `src/domain/errors.ts` | `AppError` and one helper per status code. |
| `src/domain/money.ts` | The `Cents` type and safe money helpers. |
| `src/domain/split.ts` | Even, exact and percentage splits with the largest remainder method. |
| `src/domain/settle.ts` | The "who pays whom" suggestion. |
| `src/domain/bill.ts` | Bill totals: each line shared evenly by whoever ticked it. |
| `src/dto/index.ts` | Every request schema. |
| `src/web/guestPage.ts` | The guest page's HTML, CSS and script, as one template string. |
| `scripts/seed.ts` | Puts a demo group with many expenses into a database. |
| `scripts/explain-balances.ts` | Checks that the balances pipeline uses its index. |
| `scripts/get-token.sh` | Prints an ID token for curl, using password sign-in (non-prod only). |
| `scripts/create-user.sh` | Creates a confirmed Cognito user with a known password. |
| `scripts/smoke.sh` | Walks the main API flows against a deployed stage with curl. |
| `scripts/stack-outputs.sh` | Prints the stack's outputs and writes the app's `mobile/env/<stage>.json`. |
| `test/global-setup.ts` | Starts one in-memory mongod for the whole run. |
| `test/integration/helpers.ts` | `useTestDb`, `useFakeAwsEnv`, the test users and `call()`. |
| `test/integration/router.test.ts` | Keeps the route table and `serverless.yml` in step. |
| `test/integration/db.test.ts` | How the connection finds its URI, with SSM mocked. |
| `test/integration/groups.test.ts` | Identity, groups, invites, leaving, and the outsider 404s. |
| `test/integration/money.test.ts` | Expenses, idempotency, settlements, balances and paging. |
| `test/integration/receipts.test.ts` | Receipt uploads. |
| `test/integration/account.test.ts` | Deleting an account. |
| `test/integration/bills.test.ts` | QR bills: host routes, guest routes and the bank QR. |
| `test/integration/billRace.test.ts` | A host edit landing between a guest's read and write. |
| `test/domain/*.test.ts` | Unit and property tests for money, splitting, settling and bill math. |
| `test/lib/aws.test.ts` | The SSM, S3 and Cognito wrappers with the SDK stubbed. |
| `test/web/guestPage.test.ts` | The guest page clicked through in jsdom against the real API. |

---

## 3. Ideas the code relies on

### Money is an integer number of minor units

Computers store most decimals approximately. In JavaScript, `0.1 + 0.2` is `0.30000000000000004`. Add up
enough expenses like that and balances stop summing to zero. So every amount in NetZero is a whole number of
the currency's smallest unit, called *minor units* and named `...Cents` throughout the code:

| Currency | 1 minor unit | 12.50 is stored as |
| -------- | ------------ | ------------------ |
| USD, EUR | 1 cent | `1250` |
| MNT | 1 möngö (1/100 of a tögrög) | `1250` |
| KRW, JPY | 1 won, 1 yen (there's nothing smaller) | not possible; 12 is `12` |

The backend doesn't care which currency it is. It adds and splits integers. Only display code (the app and
the guest page's `money()` function) knows where the decimal point goes.

Integers are exact in a JavaScript number up to 2^53. `MAX_CENTS` in `src/domain/money.ts` caps a single
amount at 100,000,000,000 so that even `amount x 10,000` (a percentage split in basis points) stays exact.

Three things keep floats out:

- The `Cents` type in `src/domain/money.ts` is a "branded" number. Only `cents()` makes one, and it throws
  for anything that isn't a safe integer.
- Every amount in `src/dto/index.ts` is `z.number().int()`, so `12.5` is a 400 at the door.
- ESLint (`backend/eslint.config.mjs`) bans `parseFloat` and `Math.round`.

### Splitting with the largest remainder method

When $100.00 is split three ways, someone has to get the extra cent. `largestRemainder` in
`src/domain/split.ts` decides who, the same way every time:

1. Work out each person's exact share: `total x weight / totalWeight`. For an even split every weight is 1;
   for a percentage split the weight is the basis points (33.33% is 3333).
2. Give everyone the rounded-down share.
3. Hand out the cents that are left, one each, to the people whose share lost the most to rounding (the
   biggest remainder). Ties go to the smaller user id.

Two worked examples:

| Split | Exact shares | Rounded down | Left over | Result |
| ----- | ------------ | ------------ | --------- | ------ |
| 10000 even, 3 ways | 3333.33 each | 3333 each | 1 | the smallest user id gets 3334 |
| 1000 at 33.33 / 33.33 / 33.34% | 333.3, 333.3, 333.4 | 333 each | 1 | the 33.34% person gets 334 |

The remainder is computed with integer `%`, so it's exact. Ids are compared by plain code units
(`compareIds`), never `localeCompare`, because the answer must not depend on the server's locale. The shares
always add up to exactly the total, and property tests in `test/domain/split.test.ts` throw thousands of
random cases at it to make sure.

`EXACT` splits skip this: `splitExact` only checks that the amounts are whole and add up. Bill lines use
`splitEven` for each line (`src/domain/bill.ts`).

### Idempotency keys and insert-or-fetch

The problem: the phone sends `POST /expenses`, the server saves it, and the response is lost on a flaky
connection. The phone retries. Without care, that's two expenses.

The fix: the app sends an `Idempotency-Key` header, a UUID it made when the user tapped Save, and sends the
same key on every retry of that save. `idempotent()` in `src/services/idempotency.ts` wraps the write:

1. It checks the key looks sane (`400 IDEMPOTENCY_KEY_REQUIRED` or `IDEMPOTENCY_KEY_INVALID`).
2. It hashes the method, path and raw body into `requestHash`.
3. `claimKey` (`src/repositories/idempotency.ts`) inserts `{ userId, key, requestHash, resourceId, status: 'pending' }`
   into `idempotency_keys`. A unique index on `{ userId, key }` means exactly one request can insert it.
   `resourceId` is a fresh `ObjectId` that the new document will use as its `_id`.
4. If the insert hit the unique index, this key has been seen before, and the stored row decides:

| The stored row | What happens |
| -------------- | ------------ |
| Different `requestHash` | `422 IDEMPOTENCY_KEY_REUSED`. The key was used for a different request. |
| `status: 'done'` | The stored response is returned as-is, with `idempotent-replayed: true`. Nothing is written. |
| `status: 'pending'` | An earlier attempt crashed mid-way, or is still running. Run the write again with the **same** `resourceId`. |

5. The write runs, then `completeKey` stores the response so the next retry is a pure replay.

The last row only works because the write is **insert-or-fetch**. `insertOnce` in
`src/repositories/collections.ts` inserts the document with the chosen `_id`. If a document with that `_id`
already exists, it returns the stored one instead of failing. Running the write twice with the same
`resourceId` therefore creates one document. That's the contract every `write` passed to `idempotent()` must
keep, and it's why side effects that can't be repeated (sending an email, charging a card) don't belong
inside it.

Keys are per user and expire after 7 days (a TTL index). Three routes use them: creating an expense, a
settlement, and a bill. The services validate the body and check membership *before* calling `idempotent()`,
so a rejected request never uses up a key.

### Compare-and-set on `version`

Two people edit the same expense at once. Without care, the second save silently wipes out the first. Every
expense has a `version`: 1 on create, one more on every edit. An edit (`PUT`) sends the whole expense plus
the version it was based on. `updateExpense` in `src/services/expenses.ts`:

1. Loads the expense and computes the new content, including fresh splits.
2. If the stored content already equals the request, it returns 200 with no write. That covers a retried
   edit whose first attempt went through.
3. If the stored version isn't the one the request was based on, it's `409 EXPENSE_CHANGED`. The app reloads.
4. Otherwise `updateExpenseIfVersion` in `src/repositories/expenses.ts` writes with the version **in the
   filter**: "update this expense only if its version is still 1". This compare and set happen as one atomic
   operation inside MongoDB. The update bumps the version and pushes the old content onto `history` (the last
   20 are kept, never sent to the app).
5. If that filter matched nothing, someone else wrote between our read and our write. It reads again: same
   content means 200, anything else means 409.

Edits don't need idempotency keys because this check already makes a retry harmless. Expenses created before
versioning have no `version` field; `atVersion` treats them as version 1.

### Soft delete

Deleting an expense, settlement or group doesn't remove the document. It sets `deletedAt` and `deletedBy`.
Every read that should skip deleted documents spreads `NOT_DELETED` (`{ deletedAt: { $exists: false } }`,
from `src/repositories/collections.ts`) into its filter, and the balances pipeline does the same. So a deleted
expense disappears from lists and balances but stays in the database as history.

Deleting twice returns 200 both times: `findExpenseAnyState` and `findSettlementAnyState` find the document
whether or not it's deleted, and the write only happens if it isn't yet. A deleted group behaves exactly like
one that never existed.

Bills and users are deleted for real. A bill is the host's own note, not a shared ledger, and account
deletion has to actually remove personal data.

### Balances are derived, never stored

There's no "balance" field anywhere. Every time someone opens the balances screen, `computeBalances` in
`src/aggregations/balances.ts` works them out from the ledger in one MongoDB aggregation. An edited or deleted
expense therefore changes everyone's balance automatically, and balances can't drift from the history.

An aggregation is a list of stages; each stage takes a stream of documents and passes a new stream to the
next. If it helps, read it as array code running inside MongoDB:

```
expenses.filter(e => e.groupId === g && !e.deletedAt)                       $match
  .flatMap(e => [{ user: e.paidBy, +amount }, ...e.splits.map(-share)])      $project, $unwind, $replaceWith
  .concat(settlements.filter(...).flatMap(s => [{ from, +amt }, { to, -amt }]))  $unionWith
  .groupBy(entry => entry.userId).sum()                                      $group
```

Let's run it on a real example. Alice paid 10000 for dinner split evenly between Alice, Bob and Carol, and
Bob has since paid Alice back 3333.

| Stage | What it does | Documents after it |
| ----- | ------------ | ------------------ |
| `$match` | Keeps live expenses in this group. The `{ groupId, _id }` index finds them. | the dinner: `{ paidBy: alice, amountCents: 10000, splits: [alice 3334, bob 3333, carol 3333] }` |
| `$project` | Turns each expense into a list of entries: the payer gets `+amount`, each share is `-share`. | `{ entries: [alice +10000, alice -3334, bob -3333, carol -3333] }` |
| `$unwind` | One document per entry. | 4 documents, each `{ entries: {...} }` |
| `$replaceWith` | Each document becomes just its entry. | `{ userId: alice, amountCents: 10000 }`, `{ alice, -3334 }`, `{ bob, -3333 }`, `{ carol, -3333 }` |
| `$unionWith` | Runs the same steps on live settlements and appends them: the payer gets `+amount`, the receiver `-amount`. | the 4 above plus `{ bob, +3333 }`, `{ alice, -3333 }` |
| `$group` | Sums `amountCents` per user. | `{ _id: alice, netCents: 3333 }`, `{ _id: bob, netCents: 0 }`, `{ _id: carol, netCents: -3333 }` |
| `$project` | Renames `_id` to `userId`. | `{ userId: alice, netCents: 3333 }`, ... |
| `$sort` | By user id, so the output is stable. | same, sorted |

Positive means the group owes you; negative means you owe the group. The nets always add up to zero, because
each expense adds `+amount` and `-(sum of splits) = -amount`, and each settlement adds `+x` and `-x`.

`getBalances` in `src/services/balances.ts` then lists every member (at zero if they have no entries), adds
names, and asks `suggestTransfers` in `src/domain/settle.ts` for the payments that would settle everyone up.
That function refuses (with a 500) balances that don't add up to zero, as a last safety check.

The same `computeBalances` decides whether someone may leave, be removed, delete the group or delete their
account. `npm run explain:balances -- <groupId>` (`scripts/explain-balances.ts`) prints the query plan so you
can check it uses the index.

### Cursor pagination

Lists (`GET /groups`, `/expenses`, `/settlements`, `/bills`) come back a page at a time, newest first:

```
GET /groups/{id}/expenses?limit=20                 -> { items: [20 newest], nextCursor: "66f1..." }
GET /groups/{id}/expenses?limit=20&cursor=66f1...  -> { items: [the next 20], nextCursor: ... or null }
```

`pageNewestFirst` in `src/repositories/collections.ts` sorts by `_id` descending. MongoDB `ObjectId`s start
with a timestamp, so that's creation order. The cursor is the `_id` of the last item on the previous page, and
the next page is "everything with `_id` below the cursor". It asks for `limit + 1` documents; if the extra
one comes back there's another page.

Why not `skip(40)`? `skip` makes the database walk past every skipped document, so page 500 is slow. With the
`{ groupId: 1, _id: -1 }` index, `_id < cursor` is one index seek, so every page costs the same. It's also
stable: a new expense added while you scroll appears at the top, not as a duplicate on the next page.

`pageQuery` in `src/dto/index.ts` validates `limit` (1 to 100) and the cursor (24 hex characters, else 400)
and turns the cursor into an `ObjectId`.

### Uploads: presigned POST, then confirm

Receipt photos and the host's bank QR never pass through Lambda. Lambda can't take request bodies over 6 MB,
and you'd pay for it to sit waiting on a slow upload. Instead the phone uploads straight to the private S3
bucket using a **presigned** request: a URL plus form fields signed with the Lambda's credentials, good for 5
minutes, that lets whoever holds it do exactly one thing.

```
 App                              Lambda                                    S3
  | POST .../receipt-url           |                                         |
  |------------------------------->| check membership, pick a key:           |
  |                                |   groups/{g}/expenses/{e}/{uuid}.jpg    |
  |  { uploadUrl, fields, key }    | sign a POST policy (lib/s3.ts)          |
  |<-------------------------------|                                         |
  | multipart form: fields..., file                                          |
  |------------------------------------------------------------------------->|
  | PUT .../receipt { key }        |                                         |
  |------------------------------->| key under this expense's prefix?        |
  |                                | object really there? (HEAD) ----------->|
  |                                | save the key, delete the old receipt -->|
  |  the expense, hasReceipt: true |                                         |
  |<-------------------------------|                                         |
```

It's a presigned **POST** rather than a PUT because a POST policy can carry conditions that S3 enforces:
the size must be between 1 byte and 10 MB, and the content type must be the one we signed for.

Nothing points at the new key until the app confirms it, so an upload that fails halfway never shows up as a
broken image. `requireUploadedKey` in `src/services/uploads.ts` checks the confirmed key twice: it must be a
UUID with an image extension directly under this expense's prefix (so you can't attach another expense's file
or sneak in `../`), giving `400 INVALID_UPLOAD_KEY` otherwise, and it must exist in S3 (`409 UPLOAD_NOT_FOUND`
otherwise). The replaced object is then deleted; if that fails, it's only logged, since the new key is
already saved.

To show a receipt, `GET .../receipt-url` returns a 15-minute presigned GET. The bank QR works the same way
under `users/{sub}/pay-qr/` (`createPayQrUploadUrl` and `confirmPayQr` in `src/services/account.ts`).

One AWS detail: S3 only answers "404 not found" for a missing key if the caller may list the bucket.
Otherwise it says 403, which would look like a permissions problem. That's why the Lambda's role has
`s3:ListBucket` (see section 6).

### The JWT authorizer, and why only ID tokens count

When someone signs in, Cognito gives the app two tokens:

| | ID token | Access token |
| - | -------- | ------------ |
| `token_use` | `id` | `access` |
| Who it's for | `aud` = our app client id | `client_id` = our app client id |
| Carries `email`, `email_verified`, `name` | yes | no |

API Gateway's JWT authorizer checks the signature, issuer and expiry, and that the token is for our client.
For a token without `aud`, it checks `client_id` instead, so **both** tokens get through. But the API needs
the email (for invites) and the name (for groups and bills), which only ID tokens have. So `callerFrom` in
`src/lib/http.ts` rejects anything whose `token_use` isn't `id` with `401 UNAUTHORIZED`.

The caller's identity comes only from the token: `userId` is the `sub` claim, and nothing in a request body
can change who you are. API Gateway passes claims as strings, so `email_verified` arrives as `"true"`;
`callerFrom` accepts the string or a real boolean. Emails are lower-cased, and a missing name falls back to
the part of the email before the `@`.

The public routes (`/health` and `/b/...`) have no authorizer and use `withPublicHandler`, which has no
`caller`.

### Invites are matched on a verified email

Anyone can type any email at sign-up. Cognito marks it verified only after the user enters the code it emails
them. If invites matched unverified emails, someone could sign up as `bob@example.com` without owning that
inbox and walk into Bob's groups. So:

- `listMyInvites` returns nothing until the caller's email is verified.
- `acceptInvite` and `declineInvite` answer `404 INVITE_NOT_FOUND` unless the invite is addressed to the
  caller's verified email. The invite id alone proves nothing.
- `serverless.yml` sets `AttributesRequireVerificationBeforeUpdate: [email]`, so changing your email doesn't
  take effect, in the token or anywhere else, until the new address is verified.

An invite is addressed to an email, not a user, so it works for people who haven't signed up yet. It simply
waits until someone signs in with that email verified.

### Outsiders get 404, not 403

Every group route starts with `requireMembership` in `src/services/groups.ts`, which loads the group with a
filter that includes the caller's user id. A group you're not in, a deleted group and a malformed id all give
the same `404 GROUP_NOT_FOUND`. A 403 ("this exists but you can't see it") would let a stranger confirm that a
group id is real.

The same idea runs through the rest of the API:

| Situation | Answer |
| --------- | ------ |
| Someone else's bill | `404 BILL_NOT_FOUND` (`requireOwnBill` in `src/services/bills.ts`) |
| An invite for another email | `404 INVITE_NOT_FOUND` |
| A guest update with the wrong secret | `404 GUEST_NOT_FOUND` |
| A receipt URL for a group you're not in | `404 GROUP_NOT_FOUND`, and nothing is signed |

The one 403 is `NOT_A_PARTY`: a member trying to record or delete a payment between two other people. They
can already see that payment, so there's nothing to hide.

The membership check also runs before body validation, so an outsider can't learn anything by sending
malformed bodies. `test/integration/groups.test.ts` checks every group route as an outsider.

### Rules checked inside the write

Several rules need to hold *at the moment something is written*, not just when the service last looked:
"there's still room in the group", "nobody on this bill has that name yet", "this person isn't already a
member". If the service read the document, checked, and then wrote, two requests arriving together could both
pass the check.

So the repositories put those rules into the update's **filter**. MongoDB applies a single-document update
atomically, so either the document matches every condition and is updated, or nothing happens. Examples:

- `acceptInvite` in `src/repositories/groups.ts` only matches if the invite is still there for this email,
  the user isn't a member, and `members.49` doesn't exist (fewer than 50 members). It pulls the invite and
  pushes the member in the same update.
- `addGuest` in `src/repositories/bills.ts` only matches an open bill where the guest id, the name and the
  removed-guest list don't clash and there's room.
- `addInvite` uses `$expr` to compare `members + invites` against the cap inside the filter.

When the filter matches nothing, the repository returns `null` and the service reads the document again to
explain why (`ALREADY_MEMBER`, `GROUP_FULL`, a harmless retry, and so on). That pattern appears all over
`src/services/groups.ts` and `src/services/bills.ts`.

This is also why members, invites and bill guests are **embedded** in their parent document: one document
means one atomic update, with no transactions needed.

---

## 4. Walkthroughs of the main flows

### Creating an expense

`POST /groups/{groupId}/expenses` with an `Idempotency-Key` header and
`{ description, amountCents, paidBy, split }`.

1. API Gateway checks the JWT; `src/handlers/api.ts` routes to `create` in `src/handlers/expenses.ts`.
2. `createExpense` in `src/services/expenses.ts`:
   - `requireMembership` (`src/services/groups.ts`): 404 for outsiders.
   - `CreateExpenseDto.parse` (`src/dto/index.ts`): 400 `VALIDATION_ERROR` for a missing description, a
     float amount, a malformed split.
   - `contentFor`: the payer and everyone in the split must be members (`PAYER_NOT_MEMBER`,
     `SPLIT_USER_NOT_MEMBER`), then `computeSplit` (`src/domain/split.ts`) works out every share, or throws
     `SPLIT_SUM_MISMATCH`, `SPLIT_PERCENT_MISMATCH` and friends.
3. `idempotent` (`src/services/idempotency.ts`) claims the key, or replays or resumes as described in
   section 3.
4. The write: `insertExpenseOnce` (`src/repositories/expenses.ts`) inserts with `_id = resourceId` and
   `version: 1`, through `insertOnce`.
5. `201` with `expenseJson` (`src/services/serializers.ts`), which is also stored on the key.

The next `GET .../balances` picks the expense up automatically, because balances are derived.

### Editing an expense

`PUT /groups/{groupId}/expenses/{expenseId}` with the full expense plus `version`.

1. `updateExpense` in `src/services/expenses.ts`: membership, `UpdateExpenseDto`, load the live expense
   (`findExpense`, 404 if missing or deleted), then `contentFor` recomputes the splits.
2. `sameContent` says whether the stored expense already matches. If so, 200 with no write.
3. A stale `version` is `409 EXPENSE_CHANGED`.
4. `updateExpenseIfVersion` (`src/repositories/expenses.ts`) does the compare-and-set, bumps the version,
   records `updatedAt` and `updatedBy`, and pushes the previous content (an `ExpenseVersionDoc`) onto
   `history`, capped at 20 with `$slice`.
5. If it missed, re-read and decide between 200 and 409.

Deleting is `deleteExpense`: membership, find it in any state, soft-delete if it isn't already, and return
`{ id, deleted: true }` either way.

### Inviting someone and accepting

1. **Alice invites.** `POST /groups/{groupId}/invites` with `{ email }` runs `inviteToGroup` in
   `src/services/groups.ts`. `InviteDto` trims and lower-cases the email. `addInvite` in
   `src/repositories/groups.ts` adds it only if Alice is a member, nobody in the group has that email, it
   isn't invited yet, and members plus invites are under 50. If the write misses, the service re-reads:
   `409 ALREADY_MEMBER`, a 200 with nothing changed if it was already invited, or `409 GROUP_FULL`.
2. **Bob signs up** and verifies his email with Cognito's code.
3. **Bob's app lists invites.** `GET /invites` runs `listMyInvites`, which finds live groups with an invite
   for his verified email (the `invites_email` index), skips groups he's already in, and shows the inviter's
   current name if they're still a member.
4. **Bob accepts.** `POST /groups/{groupId}/invites/{inviteId}/accept` runs `acceptInvite`. It needs a
   verified email, records Bob with `registerCaller`, then makes the one atomic update described above. If it
   misses: Bob already being a member means a retried accept, so it tidies up and returns 200; an invite that
   is his but couldn't be used means `409 GROUP_FULL`; anything else is `404 INVITE_NOT_FOUND`.

Members carry a copy of their `name` and `email` inside the group. `registerCaller` in
`src/services/users.ts` compares the token with the stored users row and, only when something changed,
rewrites that copy in every group (`refreshMemberSnapshots`).

Declining (`declineInvite`) and cancelling (`cancelInvite`, by any member) both pull the invite out.

### Settling up

1. **See who owes whom.** `GET /groups/{groupId}/balances` runs `getBalances` in `src/services/balances.ts`.
   With Alice at +6666 and Bob and Carol at -3333 each, `suggestTransfers` (`src/domain/settle.ts`) suggests
   Bob pays Alice 3333 and Carol pays Alice 3333. It repeatedly matches the biggest debtor with the biggest
   creditor, which needs at most one payment fewer than there are people.
2. **Bob pays Alice** outside the app, by bank transfer or cash.
3. **Record it.** `POST /groups/{groupId}/settlements` with an `Idempotency-Key` and
   `{ fromUserId: bob, toUserId: alice, amountCents: 3333 }` runs `createSettlement` in
   `src/services/settlements.ts`. `CreateSettlementDto` refuses paying yourself. Both people must be members
   (`400 SETTLEMENT_USER_NOT_MEMBER`), and the caller must be one of them (`403 NOT_A_PARTY`). Then the same
   `idempotent` and `insertOnce` path as expenses.
4. **Balances update.** The settlement joins the ledger through `$unionWith`, and Bob is at zero.
5. **Undo** with `DELETE .../settlements/{settlementId}`: a soft delete, again only by one of the two people.

Once everyone is at zero, members can leave (`leaveGroup`) and the group can be deleted (`deleteGroup`). Both
refuse with a 409 while money is outstanding, because nobody could settle with someone who'd left.

### The QR bill

This is the "Тооцоо" feature: one person pays a restaurant bill and everyone else, without the app, pays them
back their share. The host uses the app; guests use a web page.

**The host creates the bill.** `POST /bills` with an `Idempotency-Key` and
`{ title, currency?, items: [{ name, priceCents }], payment? }` runs `createBill` in `src/services/bills.ts`:

- `BillContentDto` checks there are 1 to 100 lines and the total fits in `MAX_CENTS`. Currency defaults to MNT.
- Inside `idempotent`, it builds the bill: the host as the first guest (id `host`, no secret), a link
  `token` of 128 random bits (22 URL-safe characters), a 6-character `code` for bank transfer notes (no
  0/O or 1/I/L, since people type it), and an id for each line (`withItemIds`).
- `insertBillOnce` saves it, and `savePaymentProfile` remembers the bank details to pre-fill the next bill.
- The response (`hostView`) is the bill plus `url: https://<api host>/b/<token>`, which the app shows as a QR
  code. The host can also upload a screenshot of their banking app's "receive money" QR once
  (`POST /me/pay-qr-url`, then `PUT /me/pay-qr`); it's shown on all their bills.

**A guest opens the link.** The phone camera opens `GET /b/{token}`:

- `page` in `src/handlers/billPage.ts` returns the same HTML for every bill (`guestPageHtml` in
  `src/web/guestPage.ts`) with strict headers. A fresh random **nonce** goes into both the
  `Content-Security-Policy` header and the page's `<script>` and `<style>` tags, so the browser runs only that
  script and that style. `connect-src 'self'` limits it to talking to our API, and `img-src` allows only our
  bucket's origin, for the bank QR. `referrer-policy: no-referrer` keeps the token out of requests to S3.
- The script reads the token from the URL and fetches `GET /b/{token}/data`. `getBillByToken` checks the
  token's shape, finds the bill by its unique `token` index, and refuses links more than 90 days old with
  `410 BILL_EXPIRED`. `guestView` adds a short-lived signed URL for the host's QR.

**The guest joins.** They type a name and tap Нэгдэх.

- The browser makes up its own `guestId` and `secret` and saves them in `localStorage` *before* sending, so
  a retry after a dropped connection reuses them.
- `POST /b/{token}/guests` runs `joinBill`. It refuses, most specific reason first, a guest id the host
  removed (`409 GUEST_REMOVED`), a closed bill (`409 BILL_CLOSED`), and a name someone already has
  (`409 NAME_TAKEN`). Names are compared by `nameKeyOf`: normalised, trimmed, spaces collapsed, lower-cased,
  so "Бат" and " бат " clash. People need distinct names because the transfer note is `<code> <name>`.
- `addGuest` in `src/repositories/bills.ts` pushes the guest with all those rules in its filter, plus "fewer
  than 50 guests". The server stores only the sha256 of the secret.
- If the guest is on the bill afterwards, the secret must match (otherwise it's someone else's id:
  `409 GUEST_ID_TAKEN`) and the answer is `201 { guestId, bill }`. That also makes a retried join harmless.
  If not, the refusal is worked out again against the fresh bill, or it's `409 BILL_FULL`.

**The guest ticks what they had.** Each tap updates the page at once and queues the full list of ticked
line ids. The page sends one `PUT /b/{token}/guests/{guestId}` at a time with `x-guest-secret`, folding
taps made in the meantime into the next request.

- `updateGuestByToken` checks the guest and secret first; a wrong secret looks exactly like a missing guest
  (404). Ticks can't change on a closed bill (409).
- `changesFor` drops ticks on lines that aren't on the bill, since the host may have just deleted one, and
  removes duplicates.
- `writeGuest` writes with an extra condition: every ticked line must still exist (`'items.id': { $all }`).
  If the host edited lines between our read and our write, the write misses, so it reloads and tries again
  with the fresh lines. The third attempt drops the condition: a tick on a vanished line is harmless, since
  totals ignore it, and better than failing. `test/integration/billRace.test.ts` stages exactly that race.
- The guest is updated through an array filter (`guests.$[g]`) rather than the `guests.$` shortcut, because
  the filter also looks inside `items` and `$` would be ambiguous.

Shared lines re-split as others tick them, so the page polls `/data` every 5 seconds while it's visible.
Totals are never stored: `billJson` in `src/services/serializers.ts` runs `computeBill`
(`src/domain/bill.ts`) on every response.

**The guest pays.** The page shows the amount, the bank and account (with copy buttons), the transfer note
and the host's QR. After transferring, the guest taps "Би төлсөн", which sends
`{ paid: true, paidCents: <the total on screen> }`. The server stores that amount, not a yes/no flag:

| | Meaning |
| - | ------- |
| `paidCents` | What the guest says they transferred. 0 means not marked. |
| `dueCents` | `totalCents - paidCents`. Positive is still owed, negative is overpaid. |
| `paid` | `paidCents > 0 && dueCents <= 0`, worked out on every read. |

So if someone ticks the same dish later and the guest's share drops, they see they overpaid; if they tick
something else, they see what's still due. "Буцаах" sends `{ paid: false }`, which stores 0. Guests saved by
an older version of the app may have only `paid: true`; that reads as "paid whatever the total is now", and
the next write replaces it with an amount.

**The host manages it.** From the app the host can tick their own lines (guest id `host`), fix anyone's ticks
or record a cash payment (`updateGuestAsHost`), edit lines (`updateBill`, which keeps line ids so ticks
survive, and whose repository update strips ticks on deleted lines from every guest), close or reopen the
bill (`setBillStatus`; a closed bill freezes lines and ticks but guests can still mark paid), replace the
link if it was shared too widely (`rotateBillToken`), remove a guest (`removeGuest`, which also remembers the
id so that browser can't quietly rejoin), or delete it (`deleteBill`). `GET /bills` lists summaries
(`billSummaryJson`) with what's owed, paid and how many have paid.

### Deleting an account

`DELETE /me` runs `deleteAccount` in `src/services/account.ts`:

1. For every group the caller is in, `netOf` checks their balance. Any non-zero balance means
   `409 BALANCES_NOT_ZERO`, with the offending groups in `details`. Nothing is deleted.
2. `leaveUnchecked` takes them out of each group; the last member out soft-deletes the group.
3. `deleteBillsForHost` deletes their bills.
4. Their bank QR image is deleted from S3. This step must succeed, because once the users row is gone,
   nothing would point at the image any more.
5. `deleteUser` removes the users row, and `deleteKeysForUser` their idempotency keys.
6. `deleteCognitoUser` (`src/lib/cognito.ts`) removes the Cognito user. It goes last so that, if anything
   earlier fails, the same token still works for a retry. Every step is safe to repeat, and a user who's
   already gone from Cognito counts as deleted.

Their expenses and settlements stay with the groups, because the other members' history depends on them.

---

## 5. The data model

All documents are described in `src/repositories/documents.ts`. A few conventions hold everywhere:

- Amounts are integers in minor units.
- A user id is a Cognito `sub`, a string. Groups, expenses, settlements and bills use MongoDB `ObjectId`s,
  which appear in URLs as 24 hex characters (`toObjectId` turns anything else into "not found").
- Arrays are **embedded** when they're small, bounded, always read with their parent, and need atomic
  checks when written. Anything that can grow without limit gets its own collection.

### `users`

| Field | Notes |
| ----- | ----- |
| `_id` | Cognito `sub`. |
| `email`, `name` | From the token, refreshed by `registerCaller`. |
| `payment?` | `{ bankName, accountNumber, accountName }` from the user's last bill. |
| `payQrKey?` | S3 key of their bank QR screenshot. |
| `createdAt`, `updatedAt` | |

Indexes: only `_id`. The row is created on `GET /me` and before any write that needs it. Older databases may
also have a `users.email_updatedAt` index; nothing uses it, and it can be dropped with
`db.users.dropIndex('email_updatedAt')`.

### `groups`

| Field | Notes |
| ----- | ----- |
| `_id` | ObjectId. |
| `name`, `currency` | Currency is a 3-letter code, USD by default. |
| `members[]` | `{ userId, email, name, joinedAt }`. |
| `invites[]?` | `{ id, email, invitedBy, invitedByName, createdAt }`. Absent on some older groups. |
| `createdBy`, `createdAt`, `updatedAt?` | |
| `deletedAt?`, `deletedBy?` | Soft delete. |

Indexes: `members_userId` (`{ 'members.userId': 1 }`) for "my groups" and every membership check, and
`invites_email` for "invites for my email".

Members and invites are embedded: together they're capped at 50 (`MAX_GROUP_SIZE`), they're always needed
with the group, and the invite and accept rules live in single atomic updates.

### `expenses`

| Field | Notes |
| ----- | ----- |
| `_id`, `groupId` | ObjectIds. `_id` comes from the idempotency key's `resourceId`. |
| `description`, `amountCents`, `paidBy` | |
| `splitType` | `EVEN`, `EXACT` or `PERCENT`, as entered. |
| `splits[]` | `{ userId, amountCents }`, computed by the server, sorted by user id. Embedded. |
| `version?` | 1 on create, +1 per edit. Absent means 1. |
| `receiptKey?` | S3 key of the receipt photo. |
| `createdBy`, `createdAt`, `updatedAt?`, `updatedBy?` | |
| `history[]?` | The last 20 replaced versions, with `changedBy` and `changedAt`. Never sent to the app. |
| `deletedAt?`, `deletedBy?` | Soft delete. |

Index: `groupId_id` (`{ groupId: 1, _id: -1 }`), which serves both newest-first paging and the balances
`$match`.

Expenses get their own collection because a group's expenses grow without limit. Splits are embedded because
they're computed with the expense, always read with it, and needed by the balances pipeline.

### `settlements`

| Field | Notes |
| ----- | ----- |
| `_id`, `groupId` | ObjectIds. |
| `fromUserId`, `toUserId`, `amountCents` | "from paid to this much". |
| `createdBy`, `createdAt` | |
| `deletedAt?`, `deletedBy?` | Soft delete. |

Index: `groupId_id`, as for expenses.

### `bills`

| Field | Notes |
| ----- | ----- |
| `_id` | ObjectId, from the idempotency key. |
| `hostUserId`, `hostName` | The host's `sub` is never sent to guests. |
| `token` | The secret in the share link. Unique. |
| `code` | 6 characters for transfer notes. |
| `title`, `currency` | Currency defaults to MNT. |
| `items[]` | `{ id, name, priceCents }`, at most 100. |
| `guests[]` | `{ id, name, nameKey?, isHost, secretHash, itemIds[], paidCents?, paid?, joinedAt, updatedAt }`, at most 50 including the host. |
| `removedGuestIds[]?` | Guest ids the host removed, the latest 200. |
| `payment` | `{ bankName, accountNumber, accountName }` or null. |
| `status` | `OPEN` or `CLOSED`. |
| `createdAt`, `updatedAt` | Links expire 90 days after `createdAt`. |

Indexes: `hostUserId_id` for "my bills", newest first, and `token_unique` for the guest page.

Lines and guests are embedded: they're bounded, the page always needs all of them, and every guest write
checks the bill's status, lines and guest list in its filter.

### `idempotency_keys`

| Field | Notes |
| ----- | ----- |
| `_id` | ObjectId. |
| `userId`, `key` | Who sent which `Idempotency-Key`. |
| `requestHash` | sha256 of method, path and body. |
| `resourceId` | The `_id` the created document uses. |
| `status` | `pending` or `done`. |
| `response?` | `{ status, body }`, replayed to retries. |
| `createdAt` | |

Indexes: `userId_key_unique` (exactly one request claims a key) and `createdAt_ttl`, which makes MongoDB
delete keys 7 days after they were created.

### How indexes get created

`ensureIndexes` in `src/repositories/indexes.ts` runs on each container's first connect. `createIndexes`
does nothing for an index that already exists, so it's cheap. It goes one collection at a time because, in
parallel, each command would open its own connection and pay a TLS and authentication handshake to Atlas.
Never change the keys of an existing index name: MongoDB refuses an index whose name matches but whose keys
don't. Add a new name instead.

---

## 6. serverless.yml, section by section

`backend/serverless.yml` describes everything that gets deployed. Serverless Framework turns it into a
CloudFormation stack named `netzero-<stage>`.

### The header

A diagram and a warning: never change a user pool property that makes CloudFormation **replace** the pool
(`Schema`, `UsernameAttributes`, `AliasAttributes`, `UserPoolName` and others). A new pool gives every user a
new `sub`, and every document is keyed on it. Only change properties AWS documents as "Update requires: No
interruption".

### `params`: what differs per stage

| Param | `prod` | every other stage | Why |
| ----- | ------ | ----------------- | --- |
| `retainPolicy` | `Retain` | `Delete` | On prod the user pool and bucket survive even if the stack is deleted. |
| `userPoolDeletionProtection` | `ACTIVE` | `INACTIVE` | Cognito itself refuses to delete the prod pool, even from the console. |
| `allowPasswordAuth` | `'false'` | `'true'` | `get-token.sh` and `smoke.sh` sign in with a plain password. The app uses SRP, so prod doesn't need password sign-in. |
| `reservedConcurrency` | `50` | `0` | Caps prod at 50 containers: at most 100 Atlas connections, and a ceiling on cost during a flood. New AWS accounts may not have enough quota to reserve any, so other stages don't. |
| `alarmEmail` | `$ALARM_EMAIL` | `$ALARM_EMAIL` | Optional; subscribes that address to the alarms. |

Dev stages are meant to be thrown away and rebuilt; prod holds real people's data.

### `provider`

- **Runtime:** Node 22 on arm64, in `ap-northeast-1`. The stage comes from `--stage`, default `dev`.
- **`memorySize: 1024`.** Lambda gives CPU in proportion to memory, and cold starts are CPU-bound (loading
  the bundle, the TLS handshake to Atlas), so more memory makes them faster. Billing is per GB-second, so
  shorter runs at more memory cost about the same.
- **`timeout: 10`** seconds, and logs kept 14 days.
- **`environment`:** `STAGE`; `MONGODB_URI_PARAM`, the *name* of the SSM parameter holding the database
  URI (the URI itself never appears in the function's settings); `MONGODB_DB` (`netzero_<stage>`);
  `RECEIPTS_BUCKET` and `USER_POOL_ID`, both filled in from resources below.
- **`logs.httpApi`:** API Gateway access logs, one JSON line per request. They record `routeKey`, the
  template, rather than the actual path, because a guest link's path contains its secret token.
- **`httpApi.authorizers.cognito`:** the JWT authorizer. It reads the `Authorization` header, trusts tokens
  issued by our user pool, and requires our app client as the audience.
- **`iam.role.statements`:** exactly what the Lambda may do.

| Permission | On | Why |
| ---------- | -- | --- |
| `s3:PutObject`, `GetObject`, `DeleteObject` | `groups/*` and `users/*` in the bucket | A signed URL can only do what the signer may do. `GetObject` also covers the HEAD before confirming. `DeleteObject` removes replaced images. |
| `s3:ListBucket` | the bucket | So HEAD on a missing key answers 404 rather than 403. |
| `ssm:GetParameter` | `/netzero/<stage>/mongodb-uri` only | Reading the URI at cold start. It's encrypted with the AWS-managed `aws/ssm` key, which already allows decrypting through SSM, so no KMS grant is needed. |
| `cognito-idp:AdminDeleteUser` | the user pool | Account deletion. |

### `build`

esbuild bundles the code. It isn't minified, so stack traces in CloudWatch stay readable, and source maps
are off because turning them on slowed module loading by about 30%. `exclude: []` bundles our own pinned AWS
SDK rather than relying on the copy in the Lambda runtime.

### `functions.api`

One function, `src/handlers/api.handler`, with one `httpApi` event per route. Routes with
`authorizer: { name: cognito }` need a valid JWT; the five without one are public: `/health` and the four
`/b/...` guest routes. `test/integration/router.test.ts` reads this list and fails if it differs from the
`routes` table in `src/handlers/api.ts`, or if the public routes change.

### `resources.Conditions`

Some properties must be *absent* on some stages rather than set to a value. These conditions turn the
params into CloudFormation conditions: `AllowPasswordAuth`, `HasReservedConcurrency`, `HasAlarmEmail`.

### `resources.Resources`

- **`UserPool`:** users sign in with their email, which Cognito verifies by emailing a code (the email is in
  Mongolian, like the app). `name` is required. Passwords need 10+ characters with a lowercase letter, an
  uppercase letter and a digit; the app's forms check the same rules. Account recovery goes through the
  verified email. `AttributesRequireVerificationBeforeUpdate` keeps a changed email from taking effect until
  it's verified, which is what makes invite matching safe. Deletion and replacement follow `retainPolicy`.
- **`UserPoolClient`:** the app's client. No client secret, because anything inside an app binary can be
  extracted. SRP and refresh-token sign-in always, plain password only where `allowPasswordAuth` is true.
  `PreventUserExistenceErrors` stops sign-in from revealing whether an email has an account. ID and access
  tokens last 60 minutes, refresh tokens 30 days.
- **`ReceiptsBucket`:** private (every public-access block on), encrypted at rest, and incomplete multipart
  uploads are cleaned up after a day. Retained on prod.
- **Alarms:** an SNS topic, an email subscription if `ALARM_EMAIL` was set, and three alarms that notify it
  and notify again when they clear:

| Alarm | Fires when |
| ----- | ---------- |
| `api-5xx` | API Gateway returned 3 or more 5xx responses in 5 minutes. |
| `lambda-errors` | The function failed outside our error handling at least once in 5 minutes: a crash during startup, a timeout, running out of memory. |
| `lambda-throttles` | A request was turned away because every allowed container was busy. |

### `resources.extensions`

These patch resources Serverless generates itself.

- **`HttpApiStage`:** throttling at API Gateway, before Lambda or Atlas pay for anything. Every route gets a
  burst of 100 and 50 requests per second. The public routes get tighter limits because anyone with a link
  can call them; `/b/{token}/data` gets the most room of those because every open guest page polls it.
  `DependsOn` names the generated route resources, because the stage can only reference routes that already
  exist.
- **`ApiLambdaFunction`:** reserved concurrency, only where `reservedConcurrency` isn't 0.

### `resources.Outputs`

The user pool id, app client id, bucket name and alarm topic. Serverless adds `HttpApiUrl` itself.
`scripts/stack-outputs.sh` reads these to write the app's config.

---

## 7. How the tests work, and how to add one

Run everything with `npm run check` from `backend/`: TypeScript, ESLint, then the tests. While working,
`npm run test:watch`, or one file with `npx vitest run test/integration/bills.test.ts`, or one test by name
with `-t 'someone outside the group'`.

### The setup

- **`backend/vitest.config.mts`** finds `test/**/*.test.ts`, sets `LOG_LEVEL=silent`, and runs
  `test/global-setup.ts` once. The hook timeout is long because the very first run downloads a MongoDB
  binary.
- **`test/global-setup.ts`** starts one in-memory `mongod` (the `mongodb-memory-server` package) and passes
  its URI to every test file with vitest's `provide` / `inject`.
- **`test/integration/helpers.ts`** has what the integration tests share:
  - `useTestDb()` points the app at a database unique to the file, empties every collection before each
    test, and drops the database afterwards.
  - `useFakeAwsEnv()` sets a bucket name, region and fake credentials. Signing a URL is pure computation, so
    real signing code runs without ever talking to AWS.
  - `alice`, `bob`, `carol` and `mallory` are test users. Mallory is the outsider.
  - `call(handler, options)` builds a fake API Gateway event and calls a real handler. `as` picks the user
    (default Alice; `null` for a public route), `claims` overrides token claims, and there are options for
    `method`, `params`, `query`, `body`, `headers` and a base64 body. It returns
    `{ status, body, headers }` with the JSON already parsed.
  - `addToGroup(groupId, user)` invites and accepts, the only way into a group.

The database is a **real** MongoDB, never a mock: the aggregation pipeline and the conditions inside
atomic updates *are* the logic, and a mock would only test what we think MongoDB does.

### What gets mocked

Only calls that would leave the machine:

| Test file | Mocks | How |
| --------- | ----- | --- |
| `integration/receipts.test.ts`, `bills.test.ts`, `account.test.ts` | `objectExists` and `deleteObject` in `src/lib/s3.ts` | `vi.mock` with `importOriginal`, so signing stays real |
| `integration/account.test.ts` | `deleteCognitoUser` in `src/lib/cognito.ts` | `vi.mock` |
| `integration/db.test.ts` | `getSecureParameter` and `forgetParameter` in `src/lib/ssm.ts` | `vi.mock` |
| `lib/aws.test.ts` | each SDK client's `send` | `vi.spyOn(SSMClient.prototype, 'send')` and so on |
| `integration/billRace.test.ts` | `updateGuestBySecret` in `src/repositories/bills.ts` | wraps the real function to run a host edit just before the guest's write |

### The kinds of test

- **Domain tests** (`test/domain/`) call pure functions. Several are property tests: thousands of random
  inputs from a small seeded generator, checking things that must always hold, such as "shares add up to the
  total". The fixed seed makes any failure reproducible.
- **Integration tests** (`test/integration/`) call handlers through `call()` and check status codes, error
  codes, response bodies and sometimes the stored documents.
- **The guest page test** (`test/web/guestPage.test.ts`) loads the real HTML into jsdom, a browser
  environment for Node, and replaces `fetch` with a function that sends each request through the real router
  in `src/handlers/api.ts`. The test then clicks buttons and ticks boxes like a guest and checks the text on
  the page, in Mongolian.

### Adding a test

Most new tests are integration tests. Put one in the file for that area, or start a new file like this:

```ts
// Short description of what this file covers.
import { randomUUID } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import * as expenses from '../../src/handlers/expenses';
import * as groups from '../../src/handlers/groups';
import { alice, call, useTestDb } from './helpers';

useTestDb();

describe('expense descriptions', () => {
  it('trims spaces around the description', async () => {
    const group = (await call(groups.create, { method: 'POST', body: { name: 'Trip' } })).body;
    const body = { description: '  Taxi  ', amountCents: 500, paidBy: alice.sub, split: { type: 'EVEN', userIds: [alice.sub] } };

    const res = await call(expenses.create, {
      method: 'POST',
      path: `/groups/${group.id}/expenses`,
      params: { groupId: group.id },
      headers: { 'Idempotency-Key': randomUUID() },
      body,
    });

    expect(res.status).toBe(201);
    expect(res.body.description).toBe('Taxi');
  });
});
```

A few habits the existing tests follow:

- Arrange, act and assert are separated by blank lines.
- Names describe behaviour in plain words: `'returns 404 to anyone but the verified invitee'`.
- Assert the error **code**, not just the status: `expect(res.body.error.code).toBe('GROUP_FULL')`.
- Routes that create money need `headers: { 'Idempotency-Key': randomUUID() }`.
- Use `as: mallory` to test the outsider case, and `as: null` for the public `/b/...` routes.
- `path` matters for idempotent routes, because it's part of the request hash.

### Adding a route

1. Add the `httpApi` event to `serverless.yml` (with `authorizer: { name: cognito }` unless it must be public).
2. Add a DTO in `src/dto/index.ts` if it takes a body.
3. Write the service function, `(req, ...pathParams) => Promise<Response>`, and any repository functions.
4. Add a one-line export to the right file in `src/handlers/`.
5. Add the route to the `routes` table in `src/handlers/api.ts`. The router test fails until steps 1 and 5
   agree.
6. A new public route also needs a throttle under `RouteSettings` in `serverless.yml` and an update to the
   router test's list of public routes.

---

## 8. A suggested reading order

Read in this order and each file will only lean on things you've already seen.

1. **`backend/serverless.yml`**, skimming. What's deployed and which routes exist.
2. **`src/handlers/api.ts`**, the route table. Then any one file in `src/handlers/`.
3. **`src/lib/http.ts`**. How a request becomes a `Request`, where the `Caller` comes from, how errors become
   responses. Glance at `src/lib/logger.ts`.
4. **`src/domain/`**: `errors.ts`, `money.ts`, `split.ts`, `settle.ts`, `bill.ts`, each with its test in
   `test/domain/`. Pure code, no setup, and the heart of the money rules.
5. **`src/dto/index.ts`**. What every request looks like.
6. **`src/repositories/documents.ts`**, then `collections.ts`, `db.ts` and `indexes.ts`. The data and how we
   reach it.
7. **`src/services/groups.ts`** with **`src/repositories/groups.ts`**. `requireMembership`, invites, and the
   "rules inside the write" pattern.
8. **`src/services/expenses.ts`**, **`src/services/idempotency.ts`**, **`src/repositories/idempotency.ts`**
   and **`src/repositories/expenses.ts`**. Creating and editing money safely.
9. **`src/aggregations/balances.ts`** and **`src/services/balances.ts`**, with section 3's walkthrough open.
10. **`src/services/settlements.ts`**.
11. **`src/services/uploads.ts`**, **`src/services/receipts.ts`** and **`src/lib/s3.ts`**. The upload flow.
12. **`src/services/serializers.ts`**, then **`src/services/bills.ts`** with **`src/repositories/bills.ts`**.
    The biggest feature.
13. **`src/handlers/billPage.ts`** and **`src/web/guestPage.ts`**. The guest page and its security headers.
14. **`src/services/account.ts`**, **`src/services/users.ts`**, **`src/lib/cognito.ts`** and
    **`src/lib/ssm.ts`**.
15. The tests: `test/integration/helpers.ts`, then `groups.test.ts`, `money.test.ts` and `bills.test.ts`,
    and finally `test/web/guestPage.test.ts`.
