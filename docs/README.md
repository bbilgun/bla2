# How NetZero works

Start here if you're new to the code. This page gives you the big picture and the handful of ideas that
explain most of the code. Then go deeper with:

- [backend.md](backend.md) covers the API: TypeScript on AWS Lambda, MongoDB, Cognito and S3.
- [mobile.md](mobile.md) covers the Flutter app: GetX, Dio and the Cognito sign-in.
- [../README.md](../README.md) covers setup, deploying, everyday commands and troubleshooting.

## What the app does

NetZero splits shared costs. People in a **group** add **expenses** ("I paid 60,000₮ for dinner, split
between the three of us"), the app works out who owes whom, and people record **settlements** when they
pay each other back. When everyone's balance is zero, the group is "net zero".

There is also a **QR bill** feature for one-off meals with people who don't have the app. The host types
the receipt into the app and shows a QR code. Guests scan it, open a small web page, tick what they ate,
and see what to transfer to the host.

## The big picture

```
┌──────────────┐   HTTPS + ID token   ┌─────────────────────────────┐        ┌───────────────┐
│ Flutter app  │ ───────────────────▶ │ API Gateway (HTTP API)      │        │ MongoDB Atlas │
│ mobile/      │                      │  checks the Cognito token,  │        │  groups,      │
│              │ ◀─────────────────── │  then calls one Lambda      │        │  expenses,    │
└──────┬───────┘        JSON          └──────────────┬──────────────┘        │  bills, ...   │
       │                                             ▼                       └───────▲───────┘
       │ sign in, sign up                 ┌─────────────────────┐                    │
       ▼                                  │ Lambda "api"        │────────────────────┘
┌──────────────┐                          │ backend/src         │
│ Cognito      │                          └─────────┬───────────┘
│ user pool    │                                    │ signs short-lived upload/view URLs
└──────────────┘                                    ▼
                    photos go straight      ┌───────────────┐
       app ───────────────────────────────▶ │ S3 bucket     │
                                            │ (private)     │
                                            └───────────────┘

Guests of a QR bill:  phone browser ──▶ API Gateway ──▶ the same Lambda (public /b/{token} routes)
```

- **Cognito** handles accounts: sign up, the email code, passwords. The app gets an ID token from it and
  sends it with every request.
- **API Gateway** checks that token before anything runs, then hands the request to the Lambda.
- **One Lambda** (`backend/src/handlers/api.ts`) serves every route. It reads and writes MongoDB.
- **S3** stores receipt photos and the host's bank QR image. The Lambda never handles the file itself;
  it signs a URL and the phone uploads directly.

## Repository map

| Path | What's there |
| ---- | ------------ |
| `backend/src/` | The API source code. Layers: handlers, services, repositories, domain. |
| `backend/test/` | Backend tests, run against a real in-memory MongoDB. |
| `backend/scripts/` | Command-line helpers: create a user, get a token, smoke test a deployed stage, seed data. |
| `backend/serverless.yml` | Everything deployed to AWS: the Lambda, routes, Cognito, the bucket, alarms. |
| `mobile/lib/` | The Flutter app source code. Layers: pages, controllers, repositories, services. |
| `mobile/test/` | App tests, using fake repositories and a fake Cognito. |
| `mobile/tool/` | Not part of the app: renders app icons and screenshots for design review. |
| `mobile/env/` | Per-stage config (API URL, Cognito ids). `example.json` shows the shape. |
| `.github/workflows/ci.yml` | Runs the backend and app checks on every push and pull request. |

## Five ideas that explain most of the code

**1. Money is always a whole number.** Amounts are stored and sent as integers in the currency's smallest
unit, called "cents" in the code: 12,500.00₮ is `1250000`, $10.00 is `1000`, ₩25,000 is `25000` because
won has no smaller unit. There are no floating-point numbers anywhere money is involved, so totals always
add up exactly.

**2. The server decides every amount.** When you split 100.00 three ways, the app only says "split evenly
between these three people". The server computes 33.34 / 33.33 / 33.33 (the "largest remainder" rule
decides who gets the extra cent). The app just displays what comes back. This means two phones can never
disagree about a balance.

**3. Saving twice never creates two expenses.** Phones lose signal halfway through requests. Every "create"
request carries an `Idempotency-Key`, a random id the app makes when you tap Save and reuses if it has to
retry. The server remembers each key and returns the first result instead of writing again.

**4. Balances are calculated, never stored.** There is no "balance" field anywhere. Every time you open a
group, the server adds up the expenses and settlements from scratch. Nothing can drift out of sync because
there is nothing to keep in sync.

**5. If you're not in a group, it doesn't exist for you.** Every group route first checks membership.
Outsiders get `404 GROUP_NOT_FOUND`, exactly as if the group id were made up, so ids can't be probed.
You join a group only by accepting an invite sent to your verified email.

## Follow one expense from tap to database

This trace touches almost every layer. Open the files as you read.

1. **Page.** On the add-expense screen (`mobile/lib/pages/add_expense_page.dart`) you fill in the form
   and tap Save.
2. **Controller.** `mobile/lib/controllers/add_expense_controller.dart` checks the form, builds the request
   body (description, amount in cents, who paid, how to split) and creates an Idempotency-Key if it doesn't
   have one for this exact form yet.
3. **Repository.** `ExpensesRepository` in `mobile/lib/repositories/repositories.dart` sends
   `POST /groups/{groupId}/expenses` through `ApiClient`.
4. **API client.** `mobile/lib/services/api_client.dart` adds the ID token from
   `mobile/lib/services/auth_service.dart` (refreshing it first if it's about to expire) and turns any
   error into an `ApiException` with a Mongolian message.
5. **API Gateway** checks the token and invokes the Lambda with the route `POST /groups/{groupId}/expenses`.
6. **Router.** `backend/src/handlers/api.ts` looks the route up and calls the expenses handler.
7. **Handler.** `backend/src/handlers/expenses.ts` runs inside `withHandler` (`backend/src/lib/http.ts`),
   which reads the caller's identity from the token and turns errors into JSON responses.
8. **Service.** `backend/src/services/expenses.ts` checks that you're in the group and that everyone named is
   a member, then computes each person's share with `backend/src/domain/split.ts`.
9. **Idempotency.** `backend/src/services/idempotency.ts` claims the key. If it was used before with the same
   body, it returns the stored response and writes nothing.
10. **Repository.** `backend/src/repositories/expenses.ts` inserts the document into MongoDB.
11. **Back in the app**, the controller closes the page, and the group screen reloads its expenses and
    balances. The balances come from the aggregation in `backend/src/aggregations/balances.ts`.

## Suggested path through the code

1. Read this page, then skim the root `README.md` so you know how to run things.
2. Backend first, because the app only makes sense once you know what the API does. Follow the reading
   order at the end of [backend.md](backend.md). Start with `backend/src/domain/` (pure logic, no
   database) and its tests in `backend/test/domain/`.
3. Then the app, following the reading order in [mobile.md](mobile.md).
4. Run the tests while you read (`npm run test:watch` in `backend/`, `flutter test` in `mobile/`). Changing
   a line and watching a test fail is the quickest way to see what a piece of code is for.

## Glossary

| Term | Meaning |
| ---- | ------- |
| Cents / minor units | The smallest unit of a currency, as an integer. All amounts in the code are in these. |
| Split: EVEN, EXACT, PERCENT | How an expense is divided: equally, by exact amounts, or by percentages (sent as basis points, so 33.33% is `3333`). |
| Settlement | A payment between two members that brings their balances back toward zero. |
| Transfer | A *suggested* settlement ("Bat pays Dorj 15,000₮"), computed from the balances. |
| Idempotency-Key | A random id sent with a create request so a retry can't create a duplicate. |
| Soft delete | Marking a document with `deletedAt` instead of removing it, so history stays intact. |
| Version | A counter on each expense. An edit must say which version it changed, so two people can't overwrite each other. |
| Invite | A pending membership addressed to an email. It turns into a member when that person accepts. |
| Bill, guest, host | The QR bill feature: the host (signed in) creates a bill, guests (no account) join it from the web page. |
| ID token | The token Cognito gives the app after sign-in. It proves who you are to the API. |
| Presigned URL / POST | A short-lived link the Lambda signs so the phone can upload to, or download from, the private bucket. |
| Stage | A separate copy of the whole backend, like `dev` or `prod`, each with its own database and user pool. |
