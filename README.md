# NetZero

Split shared costs, see who owes whom, settle up, and get back to zero.

```
 Flutter app (GetX) ──JWT──▶ API Gateway (HTTP API, Cognito JWT authorizer) ──▶ Lambda (Node 22, TS) ──▶ MongoDB Atlas
        │                                                                          │
        └──────── presigned PUT/GET (signed by Lambda) ──────▶ S3 (private receipts bucket)
```

The server owns every cent; the app only displays it.

| Folder     | What                                                                          |
| ---------- | ----------------------------------------------------------------------------- |
| `backend/` | Serverless Framework v4 service: Lambda handlers, MongoDB, Cognito, S3       |
| `mobile/`  | Flutter app: GetX controllers, Dio API client, Cognito sign-in               |

---

## First deploy (about 30 minutes, once)

You already have Node 22, Flutter, the AWS CLI and Serverless v4 installed.

### 1. AWS: sign in and set a budget alarm

```bash
aws login                      # your `netzero` profile's session has expired
aws sts get-caller-identity    # should print your account id
```

In the AWS console, go to **Billing → Budgets → Create budget → Zero spend / Monthly cost budget** and set a **$5** alert. Everything here fits in the free tier, so any charge means something is wrong.

### 2. MongoDB Atlas: free cluster + connection string

1. [cloud.mongodb.com](https://cloud.mongodb.com) → **Create** → **M0 (Free)**, provider **AWS**, region **Tokyo (ap-northeast-1)** if offered. Otherwise pick the closest region (Seoul or Singapore). Name it `netzero`.
2. **Database Access → Add user**: username `netzero-api`, autogenerate a strong password, role **Read and write to any database**. Copy the password.
3. **Network Access → Add IP → Allow access from anywhere (`0.0.0.0/0`)**. Lambda has no fixed IP. The strong password is your protection; VPC peering/PrivateLink is the production upgrade.
4. **Connect → Drivers** → copy the `mongodb+srv://…` string and put your password in it.

Store it in AWS SSM Parameter Store (encrypted, never in the repo):

```bash
aws ssm put-parameter --region ap-northeast-1 \
  --name /netzero/dev/mongodb-uri --type SecureString \
  --value 'mongodb+srv://netzero-api:<PASSWORD>@netzero.xxxxx.mongodb.net/?retryWrites=true&w=majority&appName=netzero'
```

(To change it later, add `--overwrite`.)

### 3. Deploy the backend

```bash
cd backend
npm ci
npm run check                 # typecheck + lint + 75 tests against a real in-memory mongod
npx serverless deploy --stage dev
```

The first deploy takes 2 to 4 minutes. It creates the HTTP API, 13 Lambdas, the Cognito user pool and app client, and the private S3 bucket. Indexes are created automatically on the first connection.

If Serverless asks you to log in, run `npx serverless login` (it's the same `bilguuna117` org as `hello-netzero`).

### 4. Check that it works

```bash
./scripts/stack-outputs.sh dev          # prints API URL + Cognito ids, writes mobile/env/dev.json
curl "$(aws cloudformation describe-stacks --region ap-northeast-1 --stack-name netzero-dev \
  --query "Stacks[0].Outputs[?OutputKey=='HttpApiUrl'].OutputValue" --output text)/health"
# {"ok":true,"mongoMs":...,"stage":"dev"}
```

If `/health` times out, Atlas is blocking Lambda: re-check step 2.3.

Create a test user (no email code needed) and run the full API walkthrough:

```bash
./scripts/create-user.sh you@example.com 'Passw0rd1' 'Your Name'
./scripts/smoke.sh you@example.com 'Passw0rd1'
```

The smoke test signs in, creates a group, posts the same expense twice with one `Idempotency-Key` (and checks only one is stored), reads balances, and confirms a stranger's group id returns `404 GROUP_NOT_FOUND`.

### 5. Run the app

```bash
cd ../mobile
flutter pub get
flutter run --dart-define-from-file=env/dev.json        # pick your iPhone or a simulator
```

Sign up in the app (Cognito emails you a 6-digit code) or sign in with the user from step 4.
To try groups with two people, create a second user with `create-user.sh`, sign in as them once (on a simulator), then add them by email from the first account.

---

## Everyday commands

| Task                         | Command                                                     |
| ---------------------------- | ----------------------------------------------------------- |
| Backend tests (watch)        | `cd backend && npm run test:watch`                          |
| All backend checks           | `cd backend && npm run check`                               |
| Deploy dev                   | `cd backend && npm run deploy`                              |
| Deploy a single function     | `npx serverless deploy function -f createExpense --stage dev` |
| Tail a function's logs       | `npm run logs -- createExpense`                             |
| App tests                    | `cd mobile && flutter test`                                 |
| Seed 1,000 expenses          | `MONGODB_URI='…' MONGODB_DB=netzero_dev npm run seed -- you@example.com 1000` |
| Check the balances index     | `MONGODB_URI='…' MONGODB_DB=netzero_dev npm run explain:balances -- <groupId>` |
| Tear down dev completely     | `npx serverless remove --stage dev`                         |
| Regenerate app icons         | `cd mobile && flutter test tool/brand_assets_test.dart && dart run flutter_launcher_icons` |
| Render screens for review    | `cd mobile && flutter test --update-goldens tool/screens_test.dart` → `tool/screens/*.png` |

**Finding a failed request in CloudWatch.** Every log line is JSON with `requestId`, `route`, `userId`, `status` and `code`. In **CloudWatch → Logs Insights**, pick the `/aws/lambda/netzero-dev-*` groups and run:

```
fields @timestamp, route, status, code, msg
| filter level = "error" or status >= 400
| sort @timestamp desc
```

---

## How it works

### Invariants (never relaxed)

| Invariant                               | Where it's enforced                                                        |
| --------------------------------------- | -------------------------------------------------------------------------- |
| Integer cents only, no floats           | `backend/src/domain/money.ts` (branded `Cents`), Zod `.int()`, Dart `parseCents`, ESLint bans `parseFloat`/`Math.round` |
| Server owns splits, largest remainder   | `backend/src/domain/split.ts`                                              |
| One `MongoClient` per container         | module scope in `backend/src/repositories/db.ts`                           |
| Identity only from JWT `claims.sub`     | `withHandler` in `backend/src/lib/http.ts`                                 |
| Outsiders get `404 GROUP_NOT_FOUND`     | `requireMembership` in `backend/src/services/groups.ts`, first line of every group route |
| `Idempotency-Key` on money writes       | unique `{userId, key}` index + `backend/src/services/idempotency.ts`       |
| Balances derived, never stored          | `backend/src/aggregations/balances.ts`                                     |
| Plain getters over `.obs`               | `mobile/lib/controllers/`                                                  |

### Splitting money: largest remainder

Every share is `floor(total × weight / totalWeight)`. The leftover cents go one each to the largest fractional remainders, with ties broken by user id (plain code-unit order, never locale). So:

- **$100.00 Even across 3**: 3333 r 1. The remainders tie, so the smallest user id gets 3334.
- **$100.00 at 33.33 / 33.33 / 33.34 %**: 3333, 3333, 3334 exactly. No leftover.
- **$10.00 at 33.33 / 33.33 / 33.34 %**: floors 333/333/333, one cent left, and it goes to the 33.34% person (biggest remainder: .4).

The same input gives the same output every time. Property tests throw thousands of random totals at it and assert the shares always sum to the total.

### Idempotency: what happens on a retry

1. The app creates a UUID when you tap **Save** and keeps it until the server confirms. A retry of the same form reuses it; editing the form makes a new one.
2. The server inserts `{userId, key, requestHash, resourceId}` into `idempotency_keys`. The unique index means exactly one request wins.
3. A duplicate-key error means "seen it":
   - stored response present → return it with `idempotent-replayed: true` (no write)
   - still pending (the first attempt crashed mid-way) → re-run with the **same** `resourceId`; the insert is insert-or-fetch on that `_id`, so it cannot write twice
   - different body → `422 IDEMPOTENCY_KEY_REUSED`
4. Keys expire after 7 days (TTL index).

### Balances

One aggregation over `expenses` with `$unionWith settlements`: payer `+amount`, each split `−share`, settlement sender `+amount`, receiver `−amount`, then `$group` by user. They always sum to 0 (asserted on every read). "Who pays whom" is a greedy match of biggest debtor to biggest creditor (`domain/settle.ts`), at most n−1 payments.

### Receipts

`POST …/receipt-url` checks membership, then signs a 5-minute S3 `PUT` for `groups/{groupId}/expenses/{expenseId}/{uuid}.jpg`. The phone uploads straight to the private bucket. The file never passes through Lambda (6 MB payload limit, and you'd pay for Lambda to wait on the upload). Viewing uses a 15-minute presigned `GET`.

### QR bill splitting (the "Тооцоо" tab)

For one-off bills (restaurant, party) with people who don't have the app.

1. **Host, in the app:** types the receipt's lines and where to be paid: bank, account, name, and optionally a screenshot of their bank app's "receive money" QR. `POST /bills` returns a link `https://<api>/b/<token>`, and the app shows it as a QR code.
2. **Guests:** scan with the phone camera. The link opens a single HTML page in Mongolian, served by Lambda, with no app and no account. They type a name, tick what they had, see their total, and get the bank details, the exact amount and a transfer note (`<code> <name>`), each with a copy button. Then they tap "Би төлсөн".
3. Each line is split evenly between everyone who ticked it, with the same largest-remainder rule as group expenses. Guest totals plus unclaimed always equal the bill total (`domain/bill.ts`). Totals are recomputed on every read, never stored.

**Security:**
- **The link token** is 128 random bits, and anyone holding it can see the bill and join. It is never logged.
- **Guest identity:** each guest's browser makes up its own id and secret. The server stores only the secret's sha256, and every guest write must match both, so seeing someone's id on the page isn't enough to edit them. A retried join with the same id and secret doesn't add a second guest.
- **The page itself** sets only `textContent`, never `innerHTML`, so names people type can't inject HTML. It is locked down with a nonce CSP, and its referrer policy keeps the token from leaking to S3.
- **Closing a bill** freezes the ticks, but guests can still mark themselves paid.

### Performance

| What | Why |
| ---- | --- |
| **One Lambda for every route** (`src/handlers/api.ts`) | API Gateway still routes and checks the JWT per route. With one function per route, every screen paid its own ~1 s cold start; now a session pays one (~0.7 s), then requests take 7–33 ms inside Lambda. `test/integration/router.test.ts` keeps the table in sync with `serverless.yml` and checks which routes are public. |
| **1024 MB memory** | Lambda CPU scales with memory; cold starts are CPU-bound (bundle load, TLS + SCRAM to Atlas). Billed per GB-second, so the cost barely moves. |
| **Indexes checked one collection at a time** | In parallel, each `createIndexes` opened its own pooled connection and paid a full handshake: 1.15 s → 0.6 s from a laptop, ~20 ms inside AWS. |
| **No runtime source maps** | `--enable-source-maps` added ~30% to module load. The bundle isn't minified, so stack traces stay readable. Package: 12.9 MB → 0.55 MB. |
| **App: ID token cached in memory** | Every request used to re-read the Cognito session from the Keychain. Requests starting together share one lookup. |
| **App: lazy lists, optimistic ticks** | Group expenses build rows only as they scroll into view and load the next page automatically. The host's ticks on a bill show immediately; fast taps merge into one request. |

### MongoDB collections

| Collection         | Shape                                                                      | Indexes                                  |
| ------------------ | -------------------------------------------------------------------------- | ---------------------------------------- |
| `users`            | `_id` = Cognito sub, email, name                                           | `{email, updatedAt}`                     |
| `groups`           | name, currency, **members embedded** `[{userId, email, name}]`             | `{members.userId}`                       |
| `expenses`         | groupId, amountCents, paidBy, splitType, **splits embedded** `[{userId, amountCents}]`, receiptKey | `{groupId, _id: -1}` |
| `settlements`      | groupId, fromUserId, toUserId, amountCents                                 | `{groupId, _id: -1}`                     |
| `bills`            | hostUserId, token, code, title, currency, **items** and **guests embedded** (max 50), payment, status | `{hostUserId, _id: -1}`, unique `{token}` |
| `idempotency_keys` | userId, key, requestHash, resourceId, status, response                     | unique `{userId, key}`, TTL `{createdAt}` |

---

## API

All routes except `/health` and `/b/*` need `Authorization: Bearer <Cognito ID token>`. Errors look like
`{"error": {"code": "SPLIT_SUM_MISMATCH", "message": "…", "details": [...]}}`.

| Method | Path                                                  | Body / notes                                                                 |
| ------ | ----------------------------------------------------- | ---------------------------------------------------------------------------- |
| GET    | `/health`                                             | public; pings Mongo                                                          |
| GET    | `/me`                                                 | registers the caller so they can be added by email                           |
| POST   | `/groups`                                             | `{name, currency?}`                                                          |
| GET    | `/groups`                                             | groups I belong to                                                           |
| GET    | `/groups/{groupId}`                                   |                                                                              |
| POST   | `/groups/{groupId}/members`                           | `{email}`; they must have signed in once                                     |
| POST   | `/groups/{groupId}/expenses`                          | **Idempotency-Key**; `{description, amountCents, paidBy, split}`            |
| GET    | `/groups/{groupId}/expenses?limit=20&cursor=<id>`     | newest first, cursor = last `_id`                                            |
| POST   | `/groups/{groupId}/settlements`                       | **Idempotency-Key**; `{fromUserId, toUserId, amountCents}`, caller must be one side |
| GET    | `/groups/{groupId}/settlements`                       |                                                                              |
| GET    | `/groups/{groupId}/balances`                          | `{balances: [{userId, name, netCents}], transfers: [...]}`                   |
| POST   | `/groups/{groupId}/expenses/{expenseId}/receipt-url`  | `{contentType?}` → presigned PUT                                             |
| GET    | `/groups/{groupId}/expenses/{expenseId}/receipt-url`  | presigned GET                                                                |
| POST   | `/bills`                                              | **Idempotency-Key**; `{title, currency?=MNT, items: [{name, priceCents}], payment?}` → bill with `url` |
| GET    | `/bills`                                              | my bills (summaries), newest first                                           |
| GET    | `/bills/{billId}`                                     | full bill with every guest's total                                           |
| PUT    | `/bills/{billId}`                                     | same body as create; keep `items[].id` so guests keep their ticks            |
| POST   | `/bills/{billId}/status`                              | `{status: "OPEN" | "CLOSED"}`                                                |
| PUT    | `/bills/{billId}/guests/{guestId}`                    | `{itemIds?, paid?}`; `guestId` `host` = the host's own ticks                 |
| DELETE | `/bills/{billId}/guests/{guestId}`                    | remove a guest (not the host)                                                |
| POST   | `/me/pay-qr-url`                                      | `{contentType?}` → presigned PUT for the bank QR screenshot                  |
| GET    | `/b/{token}`                                          | **public**: the guest web page (HTML)                                        |
| GET    | `/b/{token}/data`                                     | **public**: the bill as guests see it, with a presigned QR image URL         |
| POST   | `/b/{token}/guests`                                   | **public**: `{name, guestId, secret}` (made up by the browser)               |
| PUT    | `/b/{token}/guests/{guestId}`                         | **public**: header `x-guest-secret`; `{itemIds?, paid?}`                     |

`split` is one of:

```json
{ "type": "EVEN",    "userIds": ["sub-a", "sub-b"] }
{ "type": "EXACT",   "shares": [{ "userId": "sub-a", "amountCents": 700 }, { "userId": "sub-b", "amountCents": 300 }] }
{ "type": "PERCENT", "shares": [{ "userId": "sub-a", "basisPoints": 3333 }, { "userId": "sub-b", "basisPoints": 6667 }] }
```

---

## Troubleshooting

| Symptom                                                       | Fix                                                                                       |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Deploy fails: `Cannot resolve variable at "provider.environment.MONGODB_URI"` | The SSM parameter is missing or in another region. Redo step 2.             |
| `/health` returns 500 or times out after ~5s                  | Atlas Network Access must include `0.0.0.0/0`; check the user/password in the URI.        |
| `aws: Your session has expired`                               | `aws login`                                                                               |
| App shows "missing its API config"                            | Run with `--dart-define-from-file=env/dev.json` (create it with `stack-outputs.sh dev`).  |
| Sign-up email never arrives                                   | Check spam. Cognito's built-in sender allows 50 emails/day; use `create-user.sh` for test accounts. |
| Adding a member says `USER_NOT_FOUND`                         | They have to sign in to the app once first (that's when `/me` registers them).           |
| `401` from every route                                        | Token expired or from another stage's pool. Sign out and back in.                        |

## Production stage

```bash
aws ssm put-parameter --region ap-northeast-1 --name /netzero/prod/mongodb-uri --type SecureString --value '…'
cd backend && npm run deploy:prod && ./scripts/stack-outputs.sh prod
cd ../mobile && flutter build ipa --dart-define-from-file=env/prod.json
```

Use a separate Atlas database user (and ideally a separate cluster) for prod. Before real users: move Cognito email to SES, restrict Atlas network access (PrivateLink or a NAT with a fixed IP), and add CloudWatch alarms on 5xx.
