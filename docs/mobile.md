# The NetZero app: a guided tour

This is a tour of the Flutter app in `mobile/`, written for someone who has never opened it. You should
know some programming, but you don't need to know Flutter or GetX yet: section 3 explains the parts the
code uses. Read [README.md](README.md) in this folder first for the big picture of the whole system, and
the root [README.md](../README.md) for how to run things.

To follow along, open the files as they're mentioned. All paths below are relative to `mobile/`.

```bash
cd mobile
flutter run --dart-define-from-file=env/dev.json   # env/dev.json comes from backend/scripts/stack-outputs.sh dev
flutter test                                       # 172 tests, about 5 seconds
flutter analyze
```

Contents:

1. [The big picture](#1-the-big-picture)
2. [Folders, layers and files](#2-folders-layers-and-files)
3. [Flutter and GetX in this codebase](#3-flutter-and-getx-in-this-codebase)
4. [Ideas the app relies on](#4-ideas-the-app-relies-on)
5. [Walkthroughs](#5-walkthroughs)
6. [Error handling end to end](#6-error-handling-end-to-end)
7. [Tests and tools](#7-tests-and-tools)
8. [Release builds](#8-release-builds)
9. [A reading order](#9-a-reading-order)

---

## 1. The big picture

The app is a thin client. The server works out every share, balance and total; the app collects what
the user typed, sends it, and shows what comes back. That keeps the app small and means two phones can
never disagree about a number.

### The layers

```
 lib/pages/            Widgets. Draw the controller's state and forward taps to it.
     │  GetView gives each page its controller
     ▼
 lib/controllers/      One GetxController per screen. Holds screen state as observables,
     │                 runs actions, navigates, shows snackbars.
     │  plain method calls
     ▼
 lib/repositories/     One class per API area. Builds requests, parses JSON into lib/models/.
     │  get / post / put / patch / delete
     ▼
 lib/services/ApiClient       Dio. Base URL, the Authorization header, one retry after a 401,
     │                        every failure turned into an ApiException.
     │  idToken() / refreshAfterUnauthorized()
     ▼
 lib/services/AuthService     The session: sign-in flows, the cached ID token, refreshing it.
     │
     ▼
 lib/services/CognitoBackend  The Cognito SDK, with tokens kept in the Keychain or Keystore.

 Used by all of the above:  lib/models/ (data classes), lib/domain/ (money and form checks),
                            lib/app/ (routes, Mongolian text, theme, snackbars, build config)
```

Each layer only calls the one below it. A page never talks to a repository, and a controller never
touches Dio.

### From launch to the first screen

Open `lib/main.dart` and follow `main()`:

1. `WidgetsFlutterBinding.ensureInitialized()` lets us use plugins (secure storage, Sentry) before the
   first frame.
2. `initCrashReporting()` in `lib/services/crash_reporting.dart` installs handlers for uncaught errors
   and starts Sentry if a DSN was built in.
3. `AppConfig.isConfigured` (`lib/app/config.dart`) checks that the build has an API URL and Cognito ids.
   These come from `--dart-define-from-file=env/dev.json`. Without them the app shows a short "missing
   config" screen and stops.
4. `AuthService(cognito).restore()` reads the saved session from secure storage. It never touches the
   network, so the first screen appears immediately even offline. If a session is found, `userId` is set
   and the saved ID token is cached, even if it has expired. The first request that needs a token will
   refresh it.
5. The app-wide objects are registered with GetX: `AuthService`, `ApiClient` and the seven repositories,
   each with `Get.put(..., permanent: true)` so they live for the whole run.
6. `runApp(NetZeroApp(initialRoute: ...))` starts the UI on `/groups` if someone is signed in, otherwise
   on `/sign-in`.
7. `NetZeroApp.build` returns a `GetMaterialApp` with the theme, the Mongolian locale and the route table
   `pages` from `lib/app/routes.dart`.
8. GetX opens the initial route. Its **binding** runs first and registers the page's controllers (for
   `/groups`: `GroupsController`, `InvitesController` and `BillsController`). The page builds, asks for its
   controller, the controller is created, and its `onInit` starts loading data.
9. While the data loads, the page shows a pulsing placeholder (`SkeletonList` in `lib/pages/widgets.dart`).
   When the answer arrives the controller updates an observable and the page redraws.

### From a tap on Save to the API and back

Here is what happens when you add an expense. The same shape repeats for every write in the app.

```
AddExpensePage            AddExpenseController          ExpensesRepository       ApiClient           server
     │ tap Save                  │                              │                      │                  │
     │ ───────────────────────▶ save()                         │                      │                  │
     │                           │ buildBody(): validate,       │                      │                  │
     │                           │ make the JSON body           │                      │                  │
     │                           │ new Idempotency-Key unless   │                      │                  │
     │                           │ this exact body has one      │                      │                  │
     │                           │ ──────────────────────────▶ create(groupId, body,  │                  │
     │                           │                              │ idempotencyKey)      │                  │
     │                           │                              │ ───────────────────▶ post()           │
     │                           │                              │                      │ add ID token     │
     │                           │                              │                      │ ───────────────▶ │
     │                           │                              │                      │ ◀─────────────── │ 201 JSON
     │                           │                              │ ◀─────────────────── │ Map              │
     │                           │ ◀────────────────────────── Expense.fromJson       │                  │
     │ ◀──────────────────────── Expense (or null + error)     │                      │                  │
     │ Get.back(result: expense)                                │                      │                  │
     ▼
GroupDetailPage._addExpense: refreshAfterWrite() reloads balances and the first page of expenses
```

Step by step, with the methods to open:

1. `AddExpensePage._save` (`lib/pages/add_expense_page.dart`) calls `controller.save()`.
2. `AddExpenseController.save` (`lib/controllers/add_expense_controller.dart`) returns early if a save is
   already running, then calls `buildBody()`. That checks the form, fills `fieldErrors` if something is
   missing, and otherwise returns exactly the JSON the API expects. Amounts are integers in cents.
3. For a new expense, `save` makes an Idempotency-Key with `Uuid().v4()` unless it already has one for this
   exact body (section 4 explains why).
4. `ExpensesRepository.create` (`lib/repositories/repositories.dart`) calls
   `ApiClient.post('/groups/$groupId/expenses', data: body, idempotencyKey: key)`.
5. `ApiClient` (`lib/services/api_client.dart`) runs the request through `_AuthInterceptor`, which asks
   `AuthService.idToken()` for a token and sets `Authorization: Bearer ...`. If the server answers 401,
   `_send` refreshes the token and retries once.
6. The JSON response comes back as a `Map`, and the repository turns it into an `Expense` with
   `Expense.fromJson` (`lib/models/models.dart`).
7. The controller clears the key, marks the form clean and returns the expense. On failure it returns null
   and sets `error` or `fieldErrors`, which the page shows.
8. The page pops with the saved expense. `GroupDetailPage._addExpense` was awaiting that navigation, and
   now calls `GroupDetailController.refreshAfterWrite()`, which fetches the balances and first page again.
   The app never patches a balance locally; it asks the server.

---

## 2. Folders, layers and files

### What each layer does, and what it must not do

| Folder | Its job | Not allowed to |
| ------ | ------- | -------------- |
| `lib/app/` | App-wide setup: route table, Mongolian text, theme, brand, build config, `notify()`. | Hold screen state or call the API. |
| `lib/pages/` | Widgets. Read the controller's state, show it, pass taps back. Show dialogs that need a `BuildContext`. | Call repositories or `ApiClient`. Hold data that should survive a rebuild. Put a string on screen that isn't in `strings.dart`. |
| `lib/controllers/` | One `GetxController` per screen: state as observables, actions, navigation, snackbars. | Build widgets, use Dio or `ApiClient`, or do money math the server owns. |
| `lib/repositories/` | One class per API area: URL paths, request bodies, JSON into models. The only users of `ApiClient`. | Keep state, navigate, or show anything. |
| `lib/services/` | Talking to the outside: HTTP (`ApiClient`), Cognito (`AuthService`, `CognitoBackend`), the photo picker, crash reporting. | Know about screens. (`ApiClient` does go to sign-in when a session ends, through a callback tests replace.) |
| `lib/models/` | Plain data classes with hand-written `fromJson`. | Talk to the network or hold logic beyond small lookups like `Group.nameOf`. |
| `lib/domain/` | Pure functions: money parsing and formatting, form validators. | Import Flutter widgets, GetX or anything with side effects. |

### Every file in lib/

| File | What it is |
| ---- | ---------- |
| `main.dart` | Entry point: crash reporting, config check, session restore, registering services, `NetZeroApp`. |
| `app/brand.dart` | Brand colors and the logo, painted in code (`NetZeroMarkPainter`, `NetZeroMark`, `NetZeroLogo`). |
| `app/config.dart` | `AppConfig`: the API URL, Cognito ids and Sentry DSN baked in by `--dart-define`. |
| `app/notify.dart` | `notify()`: snackbars for controllers, swappable in tests. |
| `app/routes.dart` | Route names (`Routes`), path helpers, the page table with bindings, and `routeObserver`. |
| `app/strings.dart` | `S`: every user-visible string in Mongolian, plus error code and field error messages. |
| `app/theme.dart` | `buildTheme()` for light and dark mode, and `MoneyColors` for owed and owing amounts. |
| `controllers/account_controller.dart` | Account page: profile, sign out, delete account. |
| `controllers/add_expense_controller.dart` | The expense form for adding and editing: fields, split hints, body, Idempotency-Key. |
| `controllers/auth_controller.dart` | Shared by all auth pages: sign in, sign up, confirm code, password reset. |
| `controllers/bill_detail_controller.dart` | One QR bill kept live: polling, optimistic ticks, guest actions, link and delete. |
| `controllers/bill_editor_controller.dart` | Creating or editing a bill: lines, payment details, bank QR upload, Idempotency-Key. |
| `controllers/bills_controller.dart` | The bills tab: paged list, create, open. |
| `controllers/expense_controller.dart` | One expense: receipt photo, edit, delete, reload after a conflict. |
| `controllers/group_detail_controller.dart` | One group: members, invites, balances, paged expenses, group actions. Reused by pages on top of it. |
| `controllers/groups_controller.dart` | The groups tab: paged list, create group, refresh on resume. |
| `controllers/invites_controller.dart` | Invites addressed to the user: list, accept, decline. |
| `controllers/paging.dart` | `CursorList`: a newest-first list loaded a page at a time. |
| `controllers/settle_up_controller.dart` | Suggested payments, recording one with an Idempotency-Key, payment history. |
| `domain/money.dart` | The currency table, and converting between typed text and integer cents. |
| `domain/validators.dart` | Form validators for email, required fields and new passwords. |
| `models/models.dart` | Every API shape: `Me`, `Group`, `Expense`, `Balances`, `Settlement`, `Bill`, `CursorPage` and friends. |
| `pages/account_page.dart` | Profile card, sign out and delete account buttons. |
| `pages/add_expense_page.dart` | The expense form, with the even, exact and percent split sections. |
| `pages/auth_pages.dart` | `SignInPage`, `SignUpPage`, `ConfirmPage`, `ForgotPasswordPage`, `ResetPasswordPage`. |
| `pages/bill_detail_page.dart` | One bill: collected amount, QR card, the host's items, guests. |
| `pages/bill_editor_page.dart` | The bill form: title, currency, lines, bank details, bank QR. |
| `pages/bills_page.dart` | The bills tab list. |
| `pages/expense_page.dart` | One expense: splits, receipt photo, edit and delete. |
| `pages/group_detail_page.dart` | One group: balance card, members' balances, pending invites, expenses, members sheet. |
| `pages/groups_page.dart` | The groups tab: invite cards, group list, create group dialog. |
| `pages/home_page.dart` | The bottom bar that switches between the groups and bills tabs. |
| `pages/settle_up_page.dart` | Suggested payments, the amount dialog, recorded payments. |
| `pages/widgets.dart` | Shared widgets and dialogs: `MoneyText`, `Initials`, `SkeletonList`, `ErrorRetry`, `FormPopScope`, `RouteVisibility`, `confirmAction` and more. |
| `repositories/repositories.dart` | `UserRepository`, `GroupsRepository`, `InvitesRepository`, `ExpensesRepository`, `SettlementsRepository`, `ReceiptsRepository`, `BillsRepository`. |
| `services/api_client.dart` | `ApiClient`: Dio, the token header, 401 handling, presigned uploads, `mapError`. |
| `services/api_exception.dart` | `ApiException` and `GroupNotFoundException`. |
| `services/auth_service.dart` | `AuthService`: the session, the token cache, the generation counter, auth error text. |
| `services/cognito_backend.dart` | `CognitoBackend` interface and the real `AmazonCognitoBackend` with secure storage and timeouts. |
| `services/crash_reporting.dart` | `initCrashReporting()`: console logging and optional Sentry. |
| `services/photo_picker.dart` | `PhotoPicker`: wraps image_picker, returns bytes and a content type, Mongolian error text. |

---

## 3. Flutter and GetX in this codebase

This section covers only what the code uses. Each part points at a real example.

### Widgets and build()

In Flutter everything on screen is a **widget**: a small, immutable description of part of the UI. A
widget's `build(BuildContext context)` method returns more widgets, and Flutter turns that tree into
pixels. You never change a widget on screen; you build a new description and Flutter works out what
changed.

`ErrorRetry` in `lib/pages/widgets.dart` is a complete example: its `build` returns a `Center` holding a
`Column` with an icon, the message and a button.

The `BuildContext` passed to `build` is the widget's position in the tree. You need it to read the theme
(`Theme.of(context)`), to show dialogs (`showDialog(context: ...)`) and to navigate with Flutter's own
`Navigator`.

### StatelessWidget and StatefulWidget

A `StatelessWidget` has only final fields and a `build` method. It redraws when its parent rebuilds it.

A `StatefulWidget` comes with a separate `State` object that survives rebuilds. You change it with
`setState(() { ... })`, which schedules a rebuild. `State` also has `initState` and `dispose`, for things
that must be created once and cleaned up, like a `TextEditingController` or an animation.

In this app most state lives in GetX controllers, so pages are stateless. `StatefulWidget` appears only
where a widget owns something short-lived:

- `HomePage` remembers which tab is selected.
- `SkeletonList` owns the pulsing animation.
- `TextPromptDialog`, `_CreateGroupDialog` and `_AmountDialog` own their text field controller.
- `RouteVisibility` subscribes to the route observer and must unsubscribe in `dispose`.

### GetX in one paragraph

GetX is a library that bundles three things: navigation by route name, a simple dependency container,
and observable values that redraw widgets when they change. The app uses all three. Controllers extend
`GetxController`, pages extend `GetView<SomeController>`, and the app is a `GetMaterialApp`.

### Routes and bindings

`lib/app/routes.dart` lists every screen as a `GetPage` with a name, a page builder and a **binding**.
Routes can have parameters, like `/groups/:groupId`.

```dart
GetPage(
  name: Routes.group,                                   // '/groups/:groupId'
  page: () => const GroupDetailPage(),
  binding: BindingsBuilder<void>(
    () => Get.lazyPut(() => GroupDetailController(Get.parameters['groupId']!, Get.find(), Get.find())),
  ),
),
```

- `Get.toNamed(Routes.groupPath(id))` pushes a page. It returns a `Future` that completes with whatever
  the page pops with, which is how a form hands its result back (`Get.back(result: expense)`).
- `Get.offAllNamed(Routes.groups)` clears the stack and opens a route, used after sign-in and when a group
  disappears.
- When a route opens, its binding runs first. `Get.lazyPut` registers a recipe for the controller; the
  controller is created the first time something asks for it.
- `Get.parameters['groupId']` reads the `:groupId` part of the current route.
- When the route is popped, GetX deletes the controllers its binding created and calls their `onClose`.

Pages that sit on top of a group (add expense, expense, settle up) don't make their own copy of the
group. Their bindings call `Get.find<GroupDetailController>()`, which is still alive underneath them.

### GetxController and its lifecycle

A controller is a plain Dart class that extends `GetxController`. Two lifecycle methods matter:

- `onInit()` runs once, right after the controller is created. Controllers start loading here, for
  example `GroupDetailController.onInit` calls `load()`.
- `onClose()` runs when the route is popped. Controllers dispose text controllers, cancel timers and
  remove observers here (`BillDetailController.onClose` stops polling).

Always call `super.onInit()` and `super.onClose()`. `AuthService` and `ApiClient` extend `GetxService`
instead, which works the same way but is never deleted automatically.

### Observables, `.obs` and `Obx`

An observable is a value wrapped so others can be told when it changes. You make one with `.obs`:

```dart
final loading = true.obs;          // RxBool
final error = RxnString();         // a String that can be null
final group = Rxn<Group>();        // any nullable type
final expenses = <Expense>[].obs;  // RxList, which notifies on add, remove and assign
```

Read and write the value with `.value` (`loading.value = false`). Lists, sets and maps can be used
directly (`busy.add(id)`, `expenses[i] = updated`).

`Obx(() => ...)` is a widget that runs its builder function and records which observables were read
while it ran. When any of them changes, it runs the builder again. That is the whole trick:

```dart
Obx(() => controller.loading.value ? const SkeletonList() : const _TheList())
```

Two consequences show up in the code:

- **Only reads inside the builder count.** If an `Obx` builds a child widget, and that child's own `build`
  method reads observables, the outer `Obx` doesn't see those reads. So widgets like `_BalanceHero` and
  `_MyItems` wrap their own content in `Obx`.
- **An `Obx` that reads nothing observable is an error.** GetX throws if a builder doesn't read any
  observable, so wrap only the parts that depend on controller state.

### Why controllers expose plain getters over `.obs`

You'll see getters like these in `lib/controllers/group_detail_controller.dart`:

```dart
RxList<Expense> get expenses => _list.items;
int get myNetCents => balances.value?.netOf(myUserId) ?? 0;
bool get hasMore => _list.hasMore;          // reads _hasMore.value inside CursorList
```

They return plain values computed from observables that already exist. When an `Obx` calls
`controller.myNetCents`, the getter reads `balances.value`, so the `Obx` is subscribed to `balances` and
redraws when the balances change.

The tempting alternative is a getter that returns a new observable:

```dart
RxInt get myNetCents => (balances.value?.netOf(myUserId) ?? 0).obs;   // don't
```

That creates a brand new `RxInt` on every call. Nothing ever updates it, so an `Obx` that reads it never
redraws. The rule (also in the root README's invariants table) is: keep a small number of real
observables as fields, and expose everything derived from them as plain getters.

### Finding things: `Get.put`, `Get.lazyPut`, `Get.find` and `GetView`

GetX keeps one instance per type in a registry.

| Call | Meaning | Where |
| ---- | ------- | ----- |
| `Get.put(obj, permanent: true)` | Register an existing object now, for the whole app. | `main.dart`: services and repositories. |
| `Get.lazyPut(() => ...)` | Register a recipe; create on first `Get.find`. | Route bindings. |
| `Get.find<T>()` | Get the registered instance. The type often comes from the parameter it's passed to. | Bindings, and a few controllers. |
| `GetView<T>` | A `StatelessWidget` with a `controller` getter that calls `Get.find<T>()`. | Every page. |

Constructors take their dependencies as parameters (`GroupDetailController(groupId, groups, expenses)`),
and only the bindings call `Get.find`. That keeps controllers easy to test: a test passes fakes straight
to the constructor.

### Snackbars without a BuildContext

Flutter's own snackbars need a `BuildContext`, which controllers don't have. GetX's `Get.snackbar` works
without one, but it needs a running app with an overlay, which unit tests don't have.

`lib/app/notify.dart` solves both. Controllers call `notify(title, message)`, which calls a global
`notifier` function. In the app that function shows `Get.snackbar`. In tests, `recordNotifications()` from
`test/fakes.dart` replaces it with one that appends to a list, so a test can check what the user would
have seen.

### Watching the app lifecycle and other pages

Two Flutter mechanisms tell the app when it's no longer on screen:

- `WidgetsBindingObserver.didChangeAppLifecycleState` fires when the app goes to the background or comes
  back. `GroupsController` and `InvitesController` refetch on `resumed`; `BillDetailController` pauses
  polling on `paused` and resumes on `resumed`. They register in `onInit` and unregister in `onClose`.
- `RouteObserver` and `RouteAware` fire when another page is pushed on top of this one or popped off it.
  `RouteVisibility` in `lib/pages/widgets.dart` wraps this into `onCovered` and `onUncovered` callbacks.
  `HomePage` refreshes the lists when uncovered, and `BillDetailPage` pauses polling while covered.

### Forms and leaving them

Text fields use a `TextEditingController`, which holds the text. Forms live in the controller
(`AddExpenseController.description`, `AuthController.email`) so the text survives rebuilds.

`AddExpenseController` copies each field into an `RxString` as the user types (`_mirrored`), so `Obx`
widgets can show live hints like "30.00 left to assign".

`FormPopScope` in `lib/pages/widgets.dart` wraps a form page. It blocks the back button while saving,
and asks "discard your changes?" if `isDirty` is true. Both forms decide `isDirty` by comparing a JSON
snapshot of the fields with the snapshot taken when the form opened or last saved.

### Futures, `async` and `unawaited`

Network calls return a `Future`. `await` waits for it. `analysis_options.yaml` turns on the
`unawaited_futures` and `discarded_futures` lints, so every future must either be awaited or wrapped in
`unawaited(...)` to say "fire and forget, on purpose". That is why you'll see
`onPressed: () => unawaited(controller.loadMore())` in many pages: button callbacks can't be async, and
the lint wants the choice written down.

The analyzer also runs with `strict-casts`, `strict-inference` and `strict-raw-types`, so JSON values
must be cast explicitly (`json['id'] as String`) and generic types spelled out (`Get.toNamed<void>(...)`).

### Newer Dart syntax you'll meet

| Syntax | Meaning | Example |
| ------ | ------- | ------- |
| `switch` expressions | A switch that returns a value. | `S.apiError` |
| Records `(a, b)` and `({String name, ...})` | Small anonymous tuples. | `_CreateGroupDialog` pops `(name: ..., currency: ...)` |
| `for (final (index, item) in list.indexed)` | Loop with the index, destructured. | `BillEditorController.buildBody` |
| `'cursor': ?cursor` in a map | Include the entry only if the value isn't null. | `GroupsRepository.list` |
| `?trailing` in a list | Include the element only if it isn't null. | `SectionTitle` |
| `required this._expenses` | A private field set from a named constructor parameter. | `AddExpenseController` |

---

## 4. Ideas the app relies on

### Money is an integer number of minor units

Every amount in the app is an `int` counting the currency's smallest unit, called "cents" in the code
whatever the currency. 12,500.00₮ is `1250000`; $12.34 is `1234`; ₩25,000 is `25000` because won has no
smaller unit.

Why not `double`? Because binary floating point can't represent most decimal fractions exactly:
`double.parse('1.15') * 100` is `114.99999999999999`, not `115`. A test in `test/money_test.dart` shows
exactly this. So `lib/domain/money.dart` parses typed text with regular expressions and integer
arithmetic only, and formats with integer division.

The app also never computes a split or a balance. It sends intent ("split evenly between these three")
and displays what the server returns. The few sums it does (the "left to assign" hint, a bill's running
total) are only hints, and the server checks everything again.

Every currency goes through one table, `currencies` in `lib/domain/money.dart`:

| Code | Symbol | Decimals | Shown as | Notes |
| ---- | ------ | -------- | -------- | ----- |
| MNT | ₮ | 2 | `12,500₮` | Symbol after the number; `.00` hidden. The default. |
| USD | $ | 2 | `$12.34` | |
| EUR | € | 2 | `€12,500.00` | |
| GBP | £ | 2 | `£12.34` | |
| KRW | ₩ | 0 | `₩25,000` | Whole won. `12.5` is rejected. |
| JPY | ¥ | 0 | `¥1,500` | Whole yen. |
| CNY | ¥ | 2 | `¥12.34` | |

A code that isn't in the table gets two decimals and shows its code: `CHF 12.34`.

Parsing (`tryParseCents`) accepts what people actually type: `12.3`, `7,10` (a decimal comma), `25,000` or
`25 000` (thousands separators), and a pasted no-break space. Percentages are basis points, where
`33.33%` is `3333` (`tryParseBasisPoints`).

### The Idempotency-Key: created on Save, reused on retry

Phones lose signal in the middle of requests. If "save expense" times out, the app can't know whether the
server saved it. Retrying blindly could create the expense twice; not retrying could lose it.

The fix is a random id sent in the `Idempotency-Key` header. The server remembers each key with the
response it gave. If the same key arrives again, it returns the stored response instead of writing again.
The root README's "Idempotency: what happens on a retry" section explains the server side.

The app's half lives in `AddExpenseController.save`:

```dart
final encoded = jsonEncode(body);
if (encoded != _pendingBody) {
  _pendingKey = _uuid.v4();     // a different request: new key
  _pendingBody = encoded;
}
saved = await _expenses.create(group.id, body, idempotencyKey: _pendingKey!);
_pendingKey = null;             // confirmed: the next save is a new expense
_pendingBody = null;
```

- The key is made on the first tap of Save.
- If the save fails with `NETWORK`, the key is kept, and the user sees `S.saveOffline`: "tap Save again,
  it won't be recorded twice". Tapping Save again with the same form sends the same key.
- If the user changes the form, the body is different, so it's a different request with a new key.
- Once the server confirms, the key is dropped.

`BillEditorController.save` follows the same rule, and also stops pre-filling bank details once Save has
been tapped, because a late pre-fill would change the body and so the key. `SettleUpController.record`
keeps one key per "payer, receiver, amount" in `_keys`.

Edits don't need a key. `ExpensesRepository.update` sends the `version` that was edited; resending the
same edit is harmless, and an edit based on an old version gets `EXPENSE_CHANGED`.

### The token cache and refresh

Every API request needs a Cognito **ID token**, a signed JWT that expires after about an hour. Getting a
fresh one means reading the refresh token from the Keychain and, if needed, calling Cognito. Doing that on
every request would be slow, so `AuthService.idToken()` (`lib/services/auth_service.dart`) caches it:

- The token is kept in memory (`_token`, `_tokenExpires`) and used until **two minutes before it
  expires** (`_cacheFresh`). The margin covers clock skew and slow requests.
- When it's stale, `_startLoad` asks Cognito for a session. The future is stored in `_tokenLoading`, so
  requests that start at the same moment (a group page loads three things at once) share one lookup.
- If Cognito can't be reached, `idToken()` throws an `ApiException` with code `NETWORK` and **keeps** the
  session. Being offline is not being signed out.
- If Cognito says the refresh token is revoked or missing, it throws `SessionExpiredException`, and the
  session ends.

`_AuthInterceptor` in `lib/services/api_client.dart` calls `idToken()` before each request. If that
throws, the request fails with the same exception and is never sent without a token.

### Why a 401 retries once

A cached token can still be refused: Cognito may have revoked it, or the phone's clock may be wrong. So a
401 doesn't mean the session is over yet. `ApiClient._send` handles it:

1. The first 401: call `AuthService.refreshAfterUnauthorized(rejectedToken)`, which throws away the cached
   token and forces a refresh, then retry the request once with the new token.
2. If several requests got a 401 together, they share one refresh. `refreshAfterUnauthorized` returns the
   new token straight away to any request whose rejected token is already out of date.
3. A 401 on the retry means the session really is over. `_expire` calls `AuthService.expireSession()`,
   which signs out and leaves a notice, then the `onSessionExpired` callback opens the sign-in page.
   `_expiring` makes sure that happens once even if ten requests fail together.
4. The sign-in page's `AuthController.onInit` calls `takeExpiredNotice()` and shows "your session
   expired" instead of a bare form.

It retries only once so a server that keeps saying 401 can't cause a loop.

### The session generation counter

Many things in the app are asynchronous, and a slow answer can arrive after the situation has changed.
The worst case: user A's token refresh is still in flight when A signs out and B signs in. When the
refresh lands, it must not store A's token in B's session. Likewise, a 401 for A's old request must not
sign B out.

`AuthService.generation` is a counter bumped on every sign-in and sign-out. Code that awaits something
captures the counter first and compares after:

```dart
final generation = _auth.generation;
// ... await the request ...
if (generation != _auth.generation) throw error;   // the session changed meanwhile: hands off
```

You'll find this in `AuthService._load`, `AuthService.refreshAfterUnauthorized`, `ApiClient._send` and
`ApiClient._expire`. `AuthService.signIn` bumps it twice: once to retire anything still loading for the
old session, then, after waiting for that load to settle, once more for its own attempt.
`AuthService._signOut` also waits for an in-flight token load to finish before clearing storage, so a late
refresh can't write tokens back after sign-out.

The same "count, then compare" pattern guards other races:

| Counter | Guards against | File |
| ------- | -------------- | ---- |
| `CursorList._generation` | A "load more" from before a reload appending onto the fresh list. | `lib/controllers/paging.dart` |
| `GroupDetailController._refreshes` | An older refresh answering late and overwriting a newer one. | `lib/controllers/group_detail_controller.dart` |
| `BillDetailController._writes` | A poll that started before a write overwriting the write's result. | `lib/controllers/bill_detail_controller.dart` |

### Cursor paging

Long lists (groups, expenses, bills, payments) load 20 to 50 rows at a time. The server returns
`{ items, nextCursor }`, where the cursor is an opaque string; pass it back to get the next page, and a
null cursor means the end. `CursorPage` in `lib/models/models.dart` holds one page.

`CursorList<T>` in `lib/controllers/paging.dart` manages the whole list:

- `reload()` fetches the first page and replaces the list. `setFirstPage(page)` does the same with a page
  the caller fetched itself, which `GroupDetailController.load` uses to fetch the group, balances and first
  page in parallel.
- `loadMore()` appends the next page. It ignores a call while one is already running.
- Starting over bumps `_generation`, so a `loadMore` still in flight throws its page away when it lands.
  Otherwise page 2 of the old list could end up after page 1 of the new one.
- After a failed `loadMore`, `loadMoreFailed` is true and `shouldAutoLoad` is false. The list stops
  fetching by itself and the "load more" button stays, so a list that keeps failing doesn't retry in a
  loop.

Pages fetch the next page when the last row is built. Look at the `itemBuilder` in
`GroupDetailPage.build`: if `shouldAutoLoad` is true and this is the last row, it schedules
`controller.loadMore()` for after the current frame (`addPostFrameCallback`), because changing state in
the middle of a build isn't allowed. `LoadMoreFooter` shows a spinner or the button at the end.

### Bills: optimistic ticks and polls against writes

A QR bill changes from outside the app: guests tick items from their phone browsers. The host's bill page
stays current by **polling**, fetching the bill every 5 seconds (`BillDetailController.pollEvery`).
Polling pauses while the app is in the background or another page covers the bill (`_pauses` holds the
reasons), and resumes with an immediate poll.

Polling and the host's own writes can race. A poll that started before a write may answer after it, with
the bill as it was before. `BillDetailController` guards against that three ways:

- `_writes` counts writes. `poll()` remembers the count when it starts and drops its answer if a write
  happened since.
- `poll()` skips its turn entirely while any write is in flight (`busy` isn't empty).
- `_isOlder` drops an answer whose `updatedAt` is older than the bill on screen.

The host can also tick their own items. That should feel instant, so `toggleMine` is **optimistic**:

1. It computes the new set of ticked items and shows it at once through `pendingMine`. The page reads
   `myItemIds`, which prefers `pendingMine` over the server's answer.
2. If no request is in flight, it sends the full list of item ids (not "toggle item 3"), so a retried
   request can't flip a tick back.
3. Taps made while a request is in flight only update `_queuedMine`. When the request returns, the loop
   sends one follow-up with the latest list.
4. If a request fails, `pendingMine` is cleared and the ticks fall back to what the server last said.

### Presigned POST uploads

Receipt photos and the bank QR screenshot go to a private S3 bucket. The phone uploads them directly, so
the file never passes through Lambda (which has a 6 MB payload limit and bills for waiting).

`ReceiptsRepository.upload` does it in three calls:

1. `POST /groups/{g}/expenses/{e}/receipt-url` with the content type. The Lambda checks membership and
   returns a `PresignedPost`: the bucket URL, a set of signed form fields, the object `key` and `maxBytes`.
   The signature limits the size and content type and expires after a few minutes.
2. `ApiClient.postPresigned` refuses a file larger than `maxBytes` before sending anything, then sends a
   `multipart/form-data` POST to S3. The signed fields go first and the file last, because S3 ignores
   fields after the file. It uses a separate Dio client (`_s3`) without the auth interceptor, because S3
   rejects a presigned request that also carries an `Authorization` header.
3. `PUT .../receipt` with the key. The server checks the object exists and attaches it to the expense.

To show a receipt, `ReceiptsRepository.viewUrl` gets a presigned GET URL valid for 15 minutes, and
`Image.network` loads it. `UserRepository.uploadPayQr` does the same dance for the bank QR
(`/me/pay-qr-url`, then `/me/pay-qr`).

---

## 5. Walkthroughs

Each walkthrough names the methods to open, in order.

### Sign in

1. `SignInPage` (`lib/pages/auth_pages.dart`). The fields use `validateEmail` and `validateRequired` from
   `lib/domain/validators.dart`.
2. `AuthController.signIn` (`lib/controllers/auth_controller.dart`) validates the form, then runs the
   action inside `_run`, which sets `loading`, clears `error` and turns failures into an error message.
3. `AuthService.signIn` (`lib/services/auth_service.dart`) lowercases the email, waits for any sign-out
   still running, bumps the generation and calls `CognitoBackend.signIn`.
4. `AmazonCognitoBackend.signIn` (`lib/services/cognito_backend.dart`) signs in through the Cognito SDK,
   which saves the tokens in secure storage, and returns `AuthTokens`.
5. Back in `AuthService.signIn`, `userId` and the token cache are set. Cognito errors become an
   `AuthException` with Mongolian text from `friendlyError`.
6. `AuthController._enterApp` calls `GET /me` (`UserRepository.me`), which registers a new user on the
   server, then `Get.offAllNamed(Routes.groups)`.

If the account was created but never confirmed, `AuthService.signIn` throws an `AuthException` with
`needsConfirmation`. `AuthController.signIn` then sends a fresh code and opens the confirm page.

### Sign up and confirm

1. `SignUpPage`. The password field validates live with `validateNewPassword`, which mirrors the Cognito
   policy: 10 characters, a lowercase letter, an uppercase letter and a digit.
2. `AuthController.signUp` calls `AuthService.signUp`, keeps the email and password in `_pendingEmail` and
   `_pendingPassword`, and opens `/confirm`.
3. `ConfirmPage` takes the emailed code. `AuthController.confirm` calls `AuthService.confirm`, then signs
   in with the remembered password and enters the app as above.
4. "Resend code" calls `AuthController.resendCode`.

### Forgot password

1. "Forgot password?" on the sign-in page calls `AuthController.openForgotPassword`, which carries over
   the email typed there and opens `/forgot-password`.
2. `AuthController.sendResetCode` calls `AuthService.forgotPassword` and opens `/reset-password`.
3. `AuthController.setNewPassword` calls `AuthService.confirmNewPassword` with the code and new password,
   then signs straight in.

Both reset calls pass `reset: true` to `friendlyError`, which words a few errors differently ("no account
with this email" instead of "wrong email or password").

### Opening a group

1. `_GroupTile` in `lib/pages/groups_page.dart` calls `Get.toNamed(Routes.groupPath(group.id))`.
2. The binding in `lib/app/routes.dart` creates `GroupDetailController` with the `groupId` from the route.
3. `GroupDetailController.onInit` calls `load()`, which fetches the group, its balances and the first page
   of expenses in parallel with `Future.wait`, then sets `group`, `balances` and the expense list.
4. `GroupDetailPage.build` (`lib/pages/group_detail_page.dart`) shows `SkeletonList` while `loading` is
   true, `ErrorRetry` if the first load failed, and otherwise a `CustomScrollView`: `_BalanceHero`,
   `_MemberBalances`, `_PendingInvites` and the expenses, built lazily as they scroll into view.
5. If the server answers `GROUP_NOT_FOUND`, `ApiClient.mapError` produces a `GroupNotFoundException` and
   the controller calls `groupGone()`, which returns to the groups list and says the user is no longer a
   member.

When the user comes back to the home page, `HomePage._refresh` (through `RouteVisibility.onUncovered`)
refreshes the groups list, because the group may have been renamed, left or deleted.

### Adding an expense

Section 1 traced this one. The extra details:

- The add expense binding builds `AddExpenseController` from `Get.find<GroupDetailController>().group`.
  The floating button is hidden until the group has loaded, so the group is always there.
- `paidBy` defaults to the signed-in user, and everyone is included in an even split.
- The split sections (`_EvenSplit`, `_ExactSplit`, `_PercentSplit`) read live hints from the controller:
  `exactRemainingCents` and `percentRemainingBp`. "Split evenly" for percentages fills
  `33.34 / 33.33 / 33.33`, the leftover going to the first rows.
- Server validation errors land next to the right field through `_fieldErrorsFrom`, which maps paths like
  `split.shares.0.userId` and codes like `SPLIT_SUM_MISMATCH` onto the form's `split`, `amount` and
  `paidBy` fields.

### Editing and deleting an expense

1. Tapping an expense opens `/groups/:groupId/expenses/:expenseId`. `ExpenseController`
   (`lib/controllers/expense_controller.dart`) finds the expense in the group's loaded list, or keeps its
   own copy in `_latest` when it isn't there.
2. The edit button calls `ExpenseController.edit`, which opens the edit route. Its binding builds
   `AddExpenseController` with `existing:` set, and `_fill` copies the expense into the form. A percent
   split can't be filled back in, because the server only stores the resulting amounts, so
   `mustReenterPercents` shows a note asking for the percentages again.
3. `AddExpenseController.save` calls `ExpensesRepository.update` with the expense's `version`.
4. If someone else changed or deleted the expense first, the server answers `EXPENSE_CHANGED` or
   `EXPENSE_NOT_FOUND`. The controller sets `outdated`, `AddExpensePage._save` shows the explanation in a
   dialog and pops without a result.
5. Back in `ExpenseController.edit`: a saved `Expense` replaces the old one and the balances reload.
   Anything else calls `reload()`, which refreshes the group and, if the expense isn't on the first page,
   pages through with `GroupDetailController.findExpense` to find its newest version or learn it's gone.
6. Delete: `ExpensePage._delete` confirms, then `ExpenseController.delete` calls the repository. An
   `EXPENSE_NOT_FOUND` answer counts as success, since someone else already deleted it.

Attaching a receipt (`ExpenseController.attachReceipt`) picks a photo with `PhotoPicker`, uploads it as
described in section 4 and loads its view URL.

### Invites

Invites are addressed to an email. The server matches them against the user's **verified** email only, so
a user with an unverified address sees a note on the account page (`S.emailNotVerified`).

Sending and cancelling, inside a group:

1. The person icon in the group's app bar opens `_showInviteDialog`, a `TextPromptDialog`.
2. `GroupDetailController.invite` checks the address with `isValidEmail`, then calls
   `GroupsRepository.invite`. The server returns the group with its new invite, which replaces
   `group.value`, so the pending invites card appears.
3. `_InviteRow` has a cancel button that calls `GroupDetailController.cancelInvite`. If the invite was
   accepted or cancelled in the meantime (`INVITE_NOT_FOUND`), the group simply reloads.
4. The menu's "Members" sheet (`_MembersSheet`) lists members, with "remove" on everyone but the user,
   and the pending invites again.

Receiving, on the groups tab:

1. `InvitesController.load` fetches `GET /invites` when the home page opens, whenever the app comes back
   to the foreground, and when the user returns to the home page.
2. `GroupsPage` shows each invite as an `_InviteCard` above the groups.
3. Accept calls `InvitesController.accept`, then `GroupsController.joined` puts the group at the top of
   the list, and the app opens it. Decline calls `InvitesController.decline`.
4. `busy` holds invite ids with a request running, so a double tap sends one request.

### Settle up

1. The button on `_BalanceHero` opens `/groups/:groupId/settle-up`. Its binding builds `SettleUpController`
   with the group's `GroupDetailController`, whose balances already include the suggested `transfers`.
2. `SettleUpPage` lists each transfer as a `_TransferCard`. Only its payer or receiver can record it
   (`canRecord`).
3. "Record" opens `_AmountDialog`, pre-filled with the suggested amount. A smaller amount records a partial
   payment.
4. `SettleUpController.record` keys the request by "payer, receiver, amount" (`_signature`) and keeps one
   Idempotency-Key per signature in `_keys` until the server confirms. Offline, the user sees
   `S.recordOffline`; tapping again reuses the key.
5. On success it calls `GroupDetailController.refreshAfterWrite()` and reloads the payment history, then
   shows a snackbar.
6. Recorded payments are listed under the cards. The payer or receiver can delete one
   (`deleteSettlement`), for example one recorded by mistake.

The settle up page still opens when the group is settled, as "payment history".

### Creating a QR bill and watching it

1. The bills tab's button calls `BillsController.create`, which opens `/new-bill`.
2. `BillEditorController.onInit` (`lib/controllers/bill_editor_controller.dart`) starts with three blank
   lines and calls `_loadProfile`, which pre-fills the bank details saved from the last bill and shows the
   bank QR image if there is one. The pre-fill doesn't count as an unsaved change.
3. The host fills in the lines. Blank lines are skipped; a half-filled line is an error. Bank details are
   all or nothing. "Upload QR" calls `uploadQr`, which saves the screenshot to the user's profile.
4. `BillEditorController.save` calls `BillsRepository.create` with an Idempotency-Key. The page pops with
   the `Bill`.
5. `BillsController.create` reloads the list and opens the new bill at `/bills/:billId`.
6. `BillDetailController.onInit` loads the bill and starts a 5-second poll timer. `BillDetailPage` shows:
   - `_CollectedHero`: how much the guests owe and how much is marked paid, with a progress bar.
   - `_QrCard`: the QR code for `bill.url`, with Share (the system share sheet through share_plus) and Copy.
   - `_MyItems`: the host's own items, ticked through `toggleMine`.
   - `_Guests`: everyone who joined, with mark paid, mark unpaid and remove.
7. The app bar menu edits the bill (the same editor, with `existing:` set, saving with
   `BillsRepository.update`), closes or reopens it (`setOpen`), issues a new link (`rotateLink`, after
   which the old QR stops working) or deletes it.

"Mark paid" records the guest's total as the host sees it (`setPaid` sends `paidCents`). If the guest
changes their items later, `BillGuest.dueCents` shows what's still due or what was overpaid.

### Deleting the account

1. The avatar in the home page's app bar (`AccountButton`) opens `/account`.
2. `AccountController.onInit` loads the profile with `UserRepository.me`.
3. "Delete account" asks for confirmation (`AccountPage._delete`), then calls
   `AccountController.deleteAccount`, which sends `DELETE /me`.
4. If any balance isn't zero, the server answers `BALANCES_NOT_ZERO` with the groups in `details`.
   `groupNames` pulls out their names and the page shows `S.deleteAccountBlocked(names)` in a dialog.
5. On success the controller signs out, opens the sign-in page and shows "account deleted".

Signing out (`AccountController.signOut`) opens the sign-in page at once rather than waiting for secure
storage to be cleared, because the session is already forgotten in memory and a new sign-in waits for the
clearing to finish.

---

## 6. Error handling end to end

### Where errors come from

Every failure the user can see ends up as one of a few exception types, each carrying Mongolian text in
`message`.

| Source | Exception | Built in |
| ------ | --------- | -------- |
| An API request with no answer (timeout, no connection) | `ApiException`, code `NETWORK` | `ApiClient.mapError` |
| An API error response `{ error: { code, message, details } }` | `ApiException` with the server's code | `ApiClient.mapError` |
| `GROUP_NOT_FOUND` | `GroupNotFoundException` | `ApiClient.mapError` |
| A response without the API's error shape (API Gateway's 401, an HTML 502) | `ApiException`, code `UNAUTHORIZED` or `HTTP_<status>` | `ApiClient.mapError` |
| Getting a token while offline | `ApiException`, code `NETWORK` | `AuthService._load` |
| A session Cognito says is over | `SessionExpiredException` (an `ApiException` with code `UNAUTHORIZED`) | `AuthService._load` |
| An upload too big, or refused by S3 | `ApiException`, `FILE_TOO_LARGE` or `UPLOAD_FAILED` | `ApiClient.postPresigned` |
| Sign-in, sign-up and reset failures | `AuthException` | `AuthService`, using `friendlyError` |
| Camera or photo permission problems | `PhotoPickException` | `PhotoPicker.pick` |

`ApiException` (`lib/services/api_exception.dart`) keeps the details a controller may need: `code`,
`status`, `fieldErrors` (server validation errors by field path), the raw `details`, and the server's
English `serverMessage` for debugging, which is never shown.

### From code to Mongolian text

All text is in `lib/app/strings.dart`:

- `S.apiError(code)` maps every error code the backend sends to a message. Unknown codes get
  `S.somethingWentWrong`, so a newer server can't crash the app with a new code.
- `S.fieldError(path)` gives a message for a validation error on one field, because the server's own
  validation messages are English.
- `AuthService.friendlyError` maps Cognito's error codes. Every kind of "offline" maps to
  `S.noConnection` rather than "wrong password".

### `NETWORK` versus a server error

The difference matters for writes. A server error means the server answered: the write definitely did not
happen, and the message says why. `NETWORK` means the request may or may not have reached the server.
`ApiException.isNetwork` is true in exactly that case, and that's when the Idempotency-Key is kept and the
user is told retrying is safe (`S.saveOffline`, `S.recordOffline`).

### How controllers show errors

| Situation | What the user sees | Example |
| --------- | ------------------ | ------- |
| A screen's first load fails | A full-page `ErrorRetry` with "try again" | `GroupsController.load` sets `error` |
| A refresh fails with data already on screen | A snackbar; the old data stays | `notify(S.couldNotRefresh, e.message)` |
| A form fails to save | Red text by the field (`fieldErrors`) or above Save (`error`) | `AddExpenseController.save` |
| A one-off action fails | The method returns a message; the page shows it in a dialog or snackbar | `GroupDetailController.leave`, `SettleUpController.record` |
| The group is gone | Back to the groups list, with a snackbar | `GroupDetailController.groupGone` |
| The session is over | The sign-in page, with "your session expired" | `ApiClient._expire` |
| "Not found" for something being deleted | Treated as success | `ExpenseController.delete`, `BillDetailController.delete` |

### Adding a new error code

1. Add a case to `S.apiError` in `lib/app/strings.dart`.
2. Add the code to the `specific` list in `test/strings_test.dart`, which checks every listed code has its
   own message.
3. If a controller should react to it, compare `e.code` in its `on ApiException catch (e)` block.

`test/strings_test.dart` also scans `lib/` for string literals that start with two English words and fails
if it finds one outside `strings.dart`. A line that genuinely needs one, such as a library's own error
code, can be marked with a trailing `// not UI text` comment.

---

## 7. Tests and tools

### Running them

```bash
cd mobile
flutter test                                  # everything in test/
flutter test test/money_test.dart             # one file
flutter test --plain-name 'Idempotency-Key'   # tests whose name contains this
```

`flutter test` runs `test/` only. The files in `tool/` are run by hand (see below).

### How the tests are built

There is no network, AWS or real device anywhere in `test/`. Controllers and services take their
dependencies through the constructor, so each test builds them with fakes.

`test/fakes.dart` holds what several files share:

| Helper | What it does |
| ------ | ------------ |
| `recordNotifications()` and `shown` | Replace `notifier` so snackbars are recorded as `"title: message"` strings. Call it in `setUp`. |
| `networkError()`, `apiError(code)` | Ready-made `ApiException`s to throw from a fake. |
| `FakeCognito` | A `CognitoBackend` whose calls run replaceable handlers (`onSession`, `onRefresh`, `onSignIn`) and append to `log`. Give a handler a `Completer` to make a call slow and control exactly when it finishes. |
| `tokens(...)` | Builds `AuthTokens`. |
| `anu`, `bat`, `saraa`, `groupOf()`, `expenseOf()` | Sample members, a group and expenses with sensible defaults. |
| `FakeGroups` | A `GroupsRepository` holding one group in memory. Records writes in `calls`; `failWith` makes the next write fail. |
| `FakeExpenses` | Serves a list in small pages so a handful of expenses make several pages. `gate` holds `list()` calls so a test can interleave them; `failNextPage`, `failUpdate`, `failDelete` inject failures. |

A fake repository `implements` the real class, which in Dart means it promises the same methods. It
overrides the ones the test uses, and `noSuchMethod` throws for anything else, so a test fails loudly if
the code calls something unexpected.

Other fakes live in the one test file that needs them: `RecordingExpenses` (creates only) in
`add_expense_controller_test.dart`, `FakeSettlements`, `FakeInvites`, `FakeUsers`, and in
`bills_test.dart` the bill fakes `FakeBills`, `SlowBills` (holds each request until released) and
`PollingBills` (holds each poll until answered), plus `billJson()`. `bill_detail_controller_test.dart`
imports those from `bills_test.dart`.

Lower-level tests fake the layer below:

- `api_client_test.dart` gives `ApiClient` real Dio clients with a `FakeAdapter`, which answers each request
  with a handler and records the headers and body sent. That covers the 401 retry, sign-out once,
  `mapError` and the multipart upload byte by byte.
- `auth_service_test.dart` uses `FakeCognito` and an injectable `clock` to test token expiry and the
  sign-out races.
- `pages_test.dart` has widget tests. `app(home)` wraps a page in a `GetMaterialApp` like the real one, and
  `opener(page)` puts a button in front so the back button has somewhere to go. Each test `Get.put`s the
  controller first, and `tearDown(Get.reset)` clears the GetX registry.

### Adding a test

A controller test usually looks like this:

```dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGroups groups;
  late GroupDetailController controller;

  setUp(() {
    Get.testMode = true;           // lets Get.toNamed and friends run without a navigator
    recordNotifications();
    groups = FakeGroups();
    controller = GroupDetailController('g1', groups, FakeExpenses([]), myUserId: () => 'a');
  });

  test('renaming trims the name', () async {
    await controller.load();

    final message = await controller.rename('  Байр  ');

    expect(message, isNull);
    expect(groups.calls.last, 'rename Байр');
  });
}
```

Name tests in plain words for the behaviour ("stops auto-loading after a failed page"), and keep
arrange, act and assert apart with blank lines. To test a race, make the fake wait on a `Completer`,
start both operations, then complete it at the moment you want.

### What tool/ is for

`tool/` holds two Flutter tests that are really scripts. They aren't part of the app or of `flutter test`.

- `tool/brand_assets_test.dart` paints the logo from `lib/app/brand.dart` to the PNGs in `assets/brand/`:
  the iOS icon, the Android adaptive icon foreground, and the small mark in the middle of the bill QR code.
  Run it after changing the logo, then regenerate the launcher icons:
  `flutter test tool/brand_assets_test.dart && dart run flutter_launcher_icons`.
- `tool/screens_test.dart` renders the main screens with sample data to `tool/screens/*.png` at iPhone
  size, in light and dark mode, for design review without a device. Run it with
  `flutter test --update-goldens tool/screens_test.dart`. The PNGs are git-ignored, so each machine keeps
  its own; without `--update-goldens` the test compares against whatever was rendered last.

---

## 8. Release builds

Signing the Android build, turning on Sentry and building obfuscated release bundles are covered step by
step in the root README, under [Production stage](../README.md#production-stage) and
[Release builds](../README.md#release-builds). The signing setup is also described in the comment at the
top of `android/app/build.gradle.kts`.

Two things from the app side to know:

- `env/prod.json` holds the production API URL and Cognito ids, and optionally `SENTRY_DSN`. They're baked
  in at build time through `--dart-define-from-file` and read by `AppConfig`.
- Crash reports go to Sentry only when a DSN is set, with `sendDefaultPii` off
  (`lib/services/crash_reporting.dart`). Keep the `build/symbols` folder of each release, or obfuscated
  stack traces can't be read.

---

## 9. A reading order

This order builds up from the parts with no dependencies to the screens that use everything.

1. `lib/domain/money.dart` with `test/money_test.dart`: how money is handled, with no Flutter in sight.
2. `lib/models/models.dart`: what the API sends. Skim it; come back when a type comes up.
3. `lib/app/strings.dart`: skim the sections to learn the vocabulary of the UI, and read `S.apiError`.
4. `lib/services/api_exception.dart`, then `lib/services/api_client.dart`: how a request is sent and how
   failures become `ApiException`. Read `_send` slowly, with section 4 open.
5. `lib/services/cognito_backend.dart`, then `lib/services/auth_service.dart`, with
   `test/auth_service_test.dart`: the token cache and the generation counter.
6. `lib/repositories/repositories.dart`: every API call the app makes, in one file.
7. `lib/main.dart` and `lib/app/routes.dart`: how it all starts and how screens get their controllers.
8. `lib/controllers/paging.dart`, then `lib/controllers/groups_controller.dart` with
   `lib/pages/groups_page.dart` and `lib/pages/home_page.dart`: the first screen, a simple list.
9. `lib/controllers/group_detail_controller.dart` with `lib/pages/group_detail_page.dart` and
   `test/group_detail_controller_test.dart`: the busiest screen.
10. `lib/controllers/add_expense_controller.dart` with `lib/pages/add_expense_page.dart` and
    `test/add_expense_controller_test.dart`: forms and the Idempotency-Key.
11. `lib/controllers/expense_controller.dart` and `lib/controllers/settle_up_controller.dart` with their
    pages.
12. `lib/controllers/bill_editor_controller.dart` and `lib/controllers/bill_detail_controller.dart` with
    their pages and `test/bills_test.dart`: polling and optimistic updates.
13. `lib/controllers/auth_controller.dart` and `lib/pages/auth_pages.dart`, then
    `lib/controllers/account_controller.dart` and `lib/pages/account_page.dart`.
14. `lib/pages/widgets.dart`, `lib/app/theme.dart` and `lib/app/brand.dart` whenever a shared widget or a
    color catches your eye.

Run `flutter test` often as you go. Changing a line and watching which test fails is the
fastest way to learn what that line is for.
