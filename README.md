# NetZero

Split shared costs, see who owes whom, settle up, and get back to zero.

```
 Flutter app (GetX) ──JWT──▶ API Gateway (HTTP API, Cognito JWT authorizer) ──▶ Lambda (Node 22, TS) ──▶ MongoDB Atlas
        │                                                                          │
        └──────── presigned POST/GET (signed by Lambda) ─────▶ S3 (private receipts bucket)
```

The server owns every cent; the app only displays it.

New to the code? Start with [docs/README.md](docs/README.md): the big picture, then guided tours of the
[backend](docs/backend.md) and the [app](docs/mobile.md). This README covers setup and operations.

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

(To change it later, add `--overwrite`.) The Lambda reads it once per container at cold start, so the password never appears in the function's configuration or the CloudFormation template.

### 3. Deploy the backend

```bash
cd backend
npm ci
npm run check                 # typecheck + lint + tests against a real in-memory mongod
npx serverless package --stage dev   # builds the CloudFormation template without deploying: catches config mistakes
ALARM_EMAIL=you@example.com npx serverless deploy --stage dev
```

The first deploy takes 2 to 4 minutes. It creates the HTTP API, one Lambda, the Cognito user pool and app client, the private S3 bucket, and CloudWatch alarms (API 5xx, Lambda errors, Lambda throttles) on an SNS topic. With `ALARM_EMAIL` set, AWS emails you a confirmation link; click it or the alarms go nowhere. Leave it out and the alarms still exist; you can subscribe to the topic later. Indexes are created automatically on the first connection.

If Serverless asks you to log in, run `npx serverless login` (it's the same `bilguuna117` org as `hello-netzero`).

### 4. Check that it works

```bash
./scripts/stack-outputs.sh dev          # prints API URL + Cognito ids, writes mobile/env/dev.json
curl "$(aws cloudformation describe-stacks --region ap-northeast-1 --stack-name netzero-dev \
  --query "Stacks[0].Outputs[?OutputKey=='HttpApiUrl'].OutputValue" --output text)/health"
# {"ok":true,"mongoMs":...,"stage":"dev"}
```

If `/health` times out, Atlas is blocking Lambda: re-check step 2.3.

Create two test users (no email code needed; passwords need 10+ characters with a lowercase letter, an uppercase letter and a digit) and run the full API walkthrough:

```bash
./scripts/create-user.sh you@example.com 'Passw0rd123' 'Your Name'
./scripts/create-user.sh bat@example.com 'Passw0rd123' 'Bat'
FRIEND_EMAIL=bat@example.com FRIEND_PASSWORD='Passw0rd123' ./scripts/smoke.sh you@example.com 'Passw0rd123'
```

The smoke test signs in, creates a group, invites the second user who accepts, posts the same expense twice with one `Idempotency-Key` (and checks only one is stored), edits and deletes an expense (including a stale-version conflict), reads balances, and confirms a stranger's group id returns `404 GROUP_NOT_FOUND`. Without `FRIEND_EMAIL` it skips the two-person steps. The scripts sign in with a plain password, which only non-prod stages allow.

### 5. Run the app

```bash
cd ../mobile
flutter pub get
flutter run --dart-define-from-file=env/dev.json        # pick your iPhone or a simulator
```

Sign up in the app (Cognito emails you a 6-digit code) or sign in with the user from step 4.
To try groups with two people, invite the second user's email from a group; sign in as them (on a simulator) and accept the invite on the Groups screen. Invites work for emails that haven't signed up yet: they appear once that person signs up and verifies their email.

---

## Everyday commands

| Task                         | Command                                                     |
| ---------------------------- | ----------------------------------------------------------- |
| Backend tests (watch)        | `cd backend && npm run test:watch`                          |
| All backend checks           | `cd backend && npm run check`                               |
| Deploy dev                   | `cd backend && npm run deploy`                              |
| Redeploy just the code       | `npx serverless deploy function -f api --stage dev`         |
| Tail the API's logs          | `npm run logs -- api`                                       |
| Check the template, no deploy | `npx serverless package --stage dev`                       |
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
| Integer minor units only, no floats (cents; whole won/yen for KRW/JPY) | `backend/src/domain/money.ts` (branded `Cents`), Zod `.int()`, Dart `parseCents`, ESLint bans `parseFloat`/`Math.round` |
| Server owns splits, largest remainder   | `backend/src/domain/split.ts`                                              |
| One `MongoClient` per container         | module scope in `backend/src/repositories/db.ts`                           |
| Identity only from JWT `claims.sub`, ID tokens only | `withHandler` in `backend/src/lib/http.ts`                     |
| Nobody joins a group without accepting  | invites are matched only against the caller's **verified** email (`backend/src/services/groups.ts`) |
| Outsiders get `404 GROUP_NOT_FOUND`     | `requireMembership` in `backend/src/services/groups.ts`, first line of every group route |
| `Idempotency-Key` on money writes       | unique `{userId, key}` index + `backend/src/services/idempotency.ts`; the write must be insert-or-fetch (`insertOnce`) |
| Edits never overwrite someone else's    | expense `PUT` is a compare-and-set on `version`; deletes are soft (`deletedAt`) |
| No one leaves with money outstanding    | leave, remove member, delete group and delete account are refused while a balance isn't zero |
| Balances derived, never stored          | `backend/src/aggregations/balances.ts` (deleted expenses and settlements excluded) |
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

1. `POST …/receipt-url` checks membership, then signs a 5-minute S3 **presigned POST** for `groups/{groupId}/expenses/{expenseId}/{uuid}.jpg`. Unlike a presigned PUT, its policy caps the size (1 B to 10 MB) and pins the Content-Type.
2. The phone uploads straight to the private bucket as `multipart/form-data`. The file never passes through Lambda (6 MB payload limit, and you'd pay for Lambda to wait on the upload).
3. `PUT …/receipt {key}` confirms: the server checks the key is under that expense's prefix and that the object exists (HEAD), saves it, and deletes the receipt it replaced. Nothing points at a key until then, so a failed upload never shows as a broken image.

Viewing uses a 15-minute presigned `GET`. The bank QR on bills works the same way (`POST /me/pay-qr-url`, then `PUT /me/pay-qr`).

### QR bill splitting (the "Тооцоо" tab)

For one-off bills (restaurant, party) with people who don't have the app.

1. **Host, in the app:** types the receipt's lines and where to be paid: bank, account, name, and optionally a screenshot of their bank app's "receive money" QR. `POST /bills` returns a link `https://<api>/b/<token>`, and the app shows it as a QR code.
2. **Guests:** scan with the phone camera. The link opens a single HTML page in Mongolian, served by Lambda, with no app and no account. They type a name (unique on the bill, so transfer notes can be told apart), tick what they had, see their total, and get the bank details, the exact amount and a transfer note (`<code> <name>`), each with a copy button. Then they tap "Би төлсөн".
3. Each line is split evenly between everyone who ticked it, with the same largest-remainder rule as group expenses. Guest totals plus unclaimed always equal the bill total (`domain/bill.ts`). Totals are recomputed on every read, never stored.
4. **Paid is an amount, not a flag.** "Би төлсөн" stores the total the guest saw (`paidCents`). If their total changes afterwards (someone else ticks the same line, the host edits a price), the host and the guest see what's still due or what was paid too much (`dueCents`).

**Security:**
- **The link token** is 128 random bits, and anyone holding it can see the bill and join. It is never logged (API access logs record the route template, not the path). The host can replace it with a new link at any time (the old QR stops working), and every link stops working 90 days after the bill was created.
- **Removed guests** can't rejoin with the same browser identity.
- **Guest identity:** each guest's browser makes up its own id and secret. The server stores only the secret's sha256, and every guest write must match both, so seeing someone's id on the page isn't enough to edit them. A retried join with the same id and secret doesn't add a second guest.
- **The page itself** sets only `textContent`, never `innerHTML`, so names people type can't inject HTML. It is locked down with a nonce CSP, and its referrer policy keeps the token from leaking to S3.
- **Closing a bill** freezes the ticks and the lines (reopen it to edit), but guests can still mark themselves paid.

### Performance

| What | Why |
| ---- | --- |
| **One Lambda for every route** (`src/handlers/api.ts`) | API Gateway still routes and checks the JWT per route. With one function per route, every screen paid its own ~1 s cold start; now a session pays one (~0.7 s), then requests take 7–33 ms inside Lambda. `test/integration/router.test.ts` keeps the table in sync with `serverless.yml` and checks which routes are public. |
| **1024 MB memory** | Lambda CPU scales with memory; cold starts are CPU-bound (bundle load, TLS + SCRAM to Atlas). Billed per GB-second, so the cost barely moves. |
| **Mongo pool of 2 per container, API Gateway throttling** | A container serves one request at a time, so 2 sockets are plenty, and (containers × pool) stays far under Atlas M0's 500-connection limit. API Gateway rate-limits every route, the public `/b/*` routes more tightly; prod also reserves 50 concurrent Lambdas as a ceiling. |
| **Indexes checked one collection at a time** | In parallel, each `createIndexes` opened its own pooled connection and paid a full handshake: 1.15 s → 0.6 s from a laptop, ~20 ms inside AWS. |
| **No runtime source maps** | `--enable-source-maps` added ~30% to module load. The bundle isn't minified, so stack traces stay readable. Package: 12.9 MB → 0.55 MB. |
| **App: ID token cached in memory** | Every request used to re-read the Cognito session from the Keychain. Requests starting together share one lookup. |
| **App: lazy lists, optimistic ticks** | Group expenses build rows only as they scroll into view and load the next page automatically. The host's ticks on a bill show immediately; fast taps merge into one request. |

### MongoDB collections

| Collection         | Shape                                                                      | Indexes                                  |
| ------------------ | -------------------------------------------------------------------------- | ---------------------------------------- |
| `users`            | `_id` = Cognito sub, email, name, last bill payment details, payQrKey      | (by `_id` only)                          |
| `groups`           | name, currency, **members embedded** `[{userId, email, name}]`, **invites embedded** `[{id, email, invitedBy}]` (members + invites ≤ 50), deletedAt | `{members.userId}`, `{invites.email}` |
| `expenses`         | groupId, amountCents, paidBy, splitType, **splits embedded** `[{userId, amountCents}]`, receiptKey, version, last 20 versions in `history`, deletedAt | `{groupId, _id: -1}` |
| `settlements`      | groupId, fromUserId, toUserId, amountCents, deletedAt                      | `{groupId, _id: -1}`                     |
| `bills`            | hostUserId, token, code, title, currency, **items** and **guests embedded** (max 50; each guest has paidCents), removedGuestIds, payment, status | `{hostUserId, _id: -1}`, unique `{token}` |
| `idempotency_keys` | userId, key, requestHash, resourceId, status, response                     | unique `{userId, key}`, TTL `{createdAt}` |

---

## API

All routes except `/health` and `/b/*` need `Authorization: Bearer <Cognito ID token>`. Errors look like
`{"error": {"code": "SPLIT_SUM_MISMATCH", "message": "…", "details": [...]}}`.

| Method | Path | Body / notes |
| ------ | ---- | ------------ |
| GET    | `/health` | public; pings Mongo |
| GET    | `/me` | the caller (incl. `emailVerified`); refreshes their name/email in every group they're in |
| DELETE | `/me` | deletes the account: leaves every group, deletes their bills and QR image, then the Cognito user. `409 BALANCES_NOT_ZERO` (with the groups in `details`) until every balance is settled |
| POST   | `/groups` | `{name, currency?}` |
| GET    | `/groups?limit=50&cursor=<id>` | groups I belong to, newest first: `{items, nextCursor}` |
| GET    | `/groups/{groupId}` | includes `members` and pending `invites` |
| PATCH  | `/groups/{groupId}` | `{name}` |
| DELETE | `/groups/{groupId}` | any member, only when every balance is zero (`409 BALANCES_NOT_ZERO`) |
| POST   | `/groups/{groupId}/invites` | `{email}`; works whether or not they've signed up. `409 ALREADY_MEMBER`, `409 GROUP_FULL` |
| DELETE | `/groups/{groupId}/invites/{inviteId}` | a member cancels an invite |
| GET    | `/invites` | invites addressed to my **verified** email |
| POST   | `/groups/{groupId}/invites/{inviteId}/accept` | join; `404 INVITE_NOT_FOUND` for anyone but the invitee |
| POST   | `/groups/{groupId}/invites/{inviteId}/decline` | |
| POST   | `/groups/{groupId}/leave` | `409 BALANCE_NOT_ZERO`; the last member out deletes the group |
| DELETE | `/groups/{groupId}/members/{userId}` | remove someone else; `409 BALANCE_NOT_ZERO` |
| POST   | `/groups/{groupId}/expenses` | **Idempotency-Key**; `{description, amountCents, paidBy, split}` |
| GET    | `/groups/{groupId}/expenses?limit=20&cursor=<id>` | newest first, cursor = last `_id` |
| PUT    | `/groups/{groupId}/expenses/{expenseId}` | create body + `version`; `409 EXPENSE_CHANGED` if someone else changed it first |
| DELETE | `/groups/{groupId}/expenses/{expenseId}` | soft delete; any member |
| POST   | `/groups/{groupId}/settlements` | **Idempotency-Key**; `{fromUserId, toUserId, amountCents}`, caller must be one side |
| GET    | `/groups/{groupId}/settlements?limit=20&cursor=<id>` | `{items, nextCursor}` |
| DELETE | `/groups/{groupId}/settlements/{settlementId}` | soft delete; only the two people in it (`403 NOT_A_PARTY`) |
| GET    | `/groups/{groupId}/balances` | `{balances: [{userId, name, netCents}], transfers: [...]}` |
| POST   | `/groups/{groupId}/expenses/{expenseId}/receipt-url` | `{contentType?}` → presigned POST (`uploadUrl`, `fields`, `key`, `maxBytes`) |
| PUT    | `/groups/{groupId}/expenses/{expenseId}/receipt` | `{key}` after the upload; `409 UPLOAD_NOT_FOUND` if it isn't in S3 |
| GET    | `/groups/{groupId}/expenses/{expenseId}/receipt-url` | presigned GET |
| POST   | `/bills` | **Idempotency-Key**; `{title, currency?=MNT, items: [{name, priceCents}], payment?}` → bill with `url` |
| GET    | `/bills?limit=20&cursor=<id>` | my bills (summaries), newest first: `{items, nextCursor}` |
| GET    | `/bills/{billId}` | full bill with every guest's `totalCents`, `paidCents`, `dueCents` |
| PUT    | `/bills/{billId}` | same body as create; keep `items[].id` so guests keep their ticks. `409 BILL_CLOSED` when closed |
| DELETE | `/bills/{billId}` | |
| POST   | `/bills/{billId}/token` | new link; the old one stops working |
| POST   | `/bills/{billId}/status` | `{status: "OPEN" \| "CLOSED"}` |
| PUT    | `/bills/{billId}/guests/{guestId}` | `{itemIds?, paid?, paidCents?}`; `guestId` `host` = the host's own ticks |
| DELETE | `/bills/{billId}/guests/{guestId}` | remove a guest (not the host); they can't rejoin with the same id |
| POST   | `/me/pay-qr-url` | `{contentType?}` → presigned POST for the bank QR screenshot |
| PUT    | `/me/pay-qr` | `{key}` after the upload → `{payQrUrl}` |
| GET    | `/b/{token}` | **public**: the guest web page (HTML) |
| GET    | `/b/{token}/data` | **public**: the bill as guests see it, with a presigned QR image URL. `410 BILL_EXPIRED` after 90 days |
| POST   | `/b/{token}/guests` | **public**: `{name, guestId, secret}` (made up by the browser). `409 NAME_TAKEN`, `409 GUEST_REMOVED` |
| PUT    | `/b/{token}/guests/{guestId}` | **public**: header `x-guest-secret`; `{itemIds?, paid?, paidCents?}`. Unknown item ids are ignored |

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
| `/health` returns 500 right after a deploy, logs say `ParameterNotFound` | The SSM parameter is missing or in another region (the Lambda reads it at cold start). Redo step 2. |
| `/health` returns 500 or times out after ~5s                  | Atlas Network Access must include `0.0.0.0/0`; check the user/password in the URI.        |
| `aws: Your session has expired`                               | `aws login`                                                                               |
| App shows "missing its API config"                            | Run with `--dart-define-from-file=env/dev.json` (create it with `stack-outputs.sh dev`).  |
| Sign-up email never arrives                                   | Check spam. Cognito's built-in sender allows 50 emails/day; use `create-user.sh` for test accounts. |
| An invite never shows up for the person you invited          | Invites match the exact email, and only once it is verified. Check the spelling, and have them finish the email code at sign-up. |
| `401` from every route                                        | Token expired, from another stage's pool, or an access token (the API only takes ID tokens). Sign out and back in. |
| Sign-up says the password is too weak                         | 10+ characters with a lowercase letter, an uppercase letter and a digit.                  |

## Production stage

```bash
aws ssm put-parameter --region ap-northeast-1 --name /netzero/prod/mongodb-uri --type SecureString --value '…'
cd backend && npx serverless package --stage prod      # check the template first
ALARM_EMAIL=you@example.com npm run deploy:prod && ./scripts/stack-outputs.sh prod
```

Prod differs from dev on purpose (`params` in `serverless.yml`): the user pool and bucket are kept if the stack is deleted (`Retain`) and the pool has deletion protection; plain-password sign-in is off (so `get-token.sh`/`smoke.sh` don't work there); and the Lambda reserves 50 concurrent executions as a ceiling. Never change a user pool property that forces CloudFormation to replace the pool: every user would get a new `sub` and lose their data.

### Release builds

1. **Android signing (once).** Create an upload key and keep it, plus its passwords, somewhere safe outside the repo; losing it means you can't ship updates:
   ```bash
   keytool -genkey -v -keystore ~/keys/netzero-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
   Then create `mobile/android/key.properties` (git-ignored):
   ```properties
   storeFile=/Users/you/keys/netzero-upload.jks
   storePassword=…
   keyAlias=upload
   keyPassword=…
   ```
   Without it, release builds fall back to the debug key, which Google Play rejects. The app needs Android 8.0+ (sentry_flutter requires API 26).
2. **Crash reporting (optional).** Create a Flutter project at sentry.io and put its DSN in `env/prod.json` as `"SENTRY_DSN": "https://…"`. Empty or missing turns reporting off. `stack-outputs.sh` rewrites the env file, so add the DSN again after running it. Reports carry no names, emails or IPs.
3. **Build, obfuscated.** Keep `build/symbols` for each release: without it, crash stack traces can't be read.
   ```bash
   cd mobile
   flutter build appbundle --dart-define-from-file=env/prod.json --obfuscate --split-debug-info=build/symbols
   flutter build ipa       --dart-define-from-file=env/prod.json --obfuscate --split-debug-info=build/symbols
   ```

Use a separate Atlas database user (and ideally a separate cluster) for prod. Before real users: move Cognito email to SES (the built-in sender allows 50 emails/day) and restrict Atlas network access (PrivateLink or a NAT with a fixed IP).

The app includes account deletion (Account page → delete account), which the App Store requires. It's refused while the person still owes or is owed money in any group.
