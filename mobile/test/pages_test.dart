import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/app/theme.dart';
import 'package:netzero/controllers/add_expense_controller.dart';
import 'package:netzero/controllers/auth_controller.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/pages/add_expense_page.dart';
import 'package:netzero/pages/auth_pages.dart';
import 'package:netzero/services/auth_service.dart';

import 'fakes.dart';

Widget app(Widget home) => GetMaterialApp(
  theme: buildTheme(Brightness.light),
  locale: const Locale('mn'),
  supportedLocales: const [Locale('mn')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: home,
);

/// A first page with a button that opens [page], so the back button has somewhere to go.
Widget opener(Widget page) => app(
  Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  late FakeCognito cognito;
  late AuthService auth;

  setUp(() {
    Get.testMode = true;
    recordNotifications();
    cognito = FakeCognito(now: DateTime.now);
    auth = AuthService(cognito);
  });

  tearDown(Get.reset);

  group('sign in', () {
    testWidgets('empty fields: each says what is missing, and nothing is sent', (tester) async {
      Get.put(AuthController(auth));
      await tester.pumpWidget(app(const SignInPage()));
      await tester.tap(find.widgetWithText(FilledButton, S.signIn));
      await tester.pump();
      expect(find.text(S.enterValidEmail), findsOneWidget);
      expect(find.text(S.enterPassword), findsOneWidget);
      expect(cognito.log, isEmpty);
    });

    testWidgets('a malformed email is caught before Cognito', (tester) async {
      Get.put(AuthController(auth));
      await tester.pumpWidget(app(const SignInPage()));
      await tester.enterText(find.byType(TextFormField).at(0), 'bat@x');
      await tester.enterText(find.byType(TextFormField).at(1), 'whatever');
      await tester.tap(find.widgetWithText(FilledButton, S.signIn));
      await tester.pump();
      expect(find.text(S.enterValidEmail), findsOneWidget);
      expect(cognito.log, isEmpty);
    });

    testWidgets('offline (any transport error, not just DNS) says "no connection"', (tester) async {
      cognito.onSignIn = (_, _) async => throw CognitoClientException('Unknown Error', code: 'Unknown error');
      Get.put(AuthController(auth));
      await tester.pumpWidget(app(const SignInPage()));
      await tester.enterText(find.byType(TextFormField).at(0), 'bat@x.mn');
      await tester.enterText(find.byType(TextFormField).at(1), 'Password123');
      await tester.tap(find.widgetWithText(FilledButton, S.signIn));
      await tester.pumpAndSettle();
      expect(find.text(S.noConnection), findsOneWidget);
    });

    testWidgets('after the session expired on its own, the sign-in page says so', (tester) async {
      await auth.expireSession();
      Get.put(AuthController(auth));
      await tester.pumpWidget(app(const SignInPage()));
      expect(find.text(S.sessionExpired), findsOneWidget);
    });

    testWidgets('links to "forgot password"', (tester) async {
      Get.put(AuthController(auth));
      await tester.pumpWidget(app(const SignInPage()));
      expect(find.text(S.forgotPassword), findsOneWidget);
    });
  });

  testWidgets('sign up checks the password rules and names what is missing', (tester) async {
    Get.put(AuthController(auth));
    await tester.pumpWidget(app(const SignUpPage()));
    await tester.enterText(find.byType(TextFormField).at(0), 'Бат');
    await tester.enterText(find.byType(TextFormField).at(1), 'bat@x.mn');
    await tester.enterText(find.byType(TextFormField).at(2), 'password12');
    await tester.tap(find.widgetWithText(FilledButton, S.createAccount));
    await tester.pump();
    expect(find.text(S.passwordNeeds([S.uppercaseLetter])), findsOneWidget);
    expect(cognito.log, isEmpty);

    await tester.enterText(find.byType(TextFormField).at(2), 'Password12');
    await tester.tap(find.widgetWithText(FilledButton, S.createAccount));
    await tester.pump();
    expect(cognito.log, ['signUp bat@x.mn']);
  });

  group('add expense form', () {
    AddExpenseController put({Expense? existing}) =>
        Get.put(AddExpenseController(group: groupOf(), myUserId: 'a', expenses: FakeExpenses([]), existing: existing));

    testWidgets('Save with nothing filled in shows the errors next to the fields', (tester) async {
      put();
      await tester.pumpWidget(app(const AddExpensePage()));
      final save = find.widgetWithText(FilledButton, S.save);
      await tester.scrollUntilVisible(save, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(save);
      await tester.pump();
      await tester.scrollUntilVisible(find.text(S.whatWasItFor), -300, scrollable: find.byType(Scrollable).first);
      expect(find.text(S.whatWasItFor), findsOneWidget);
      expect(find.text(S.amountHint), findsOneWidget);
    });

    testWidgets('exact and percent fields are announced with the member they belong to', (tester) async {
      final semantics = tester.ensureSemantics();
      final c = put();
      await tester.pumpWidget(app(const AddExpensePage()));
      c.splitType.value = SplitType.exact;
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp(S.exactShareFor('Bat'))), findsOneWidget);
      c.splitType.value = SplitType.percent;
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp(S.percentShareFor('Saraa'))), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('edit mode: its own title, filled in', (tester) async {
      put(existing: expenseOf('e1', description: 'Taxi', amountCents: 2500));
      await tester.pumpWidget(app(const AddExpensePage()));
      expect(find.text(S.editExpense), findsOneWidget);
      expect(find.text('Taxi'), findsOneWidget);
      expect(find.text('25.00'), findsOneWidget);
    });

    testWidgets('back with unsaved changes asks first; untouched goes straight back', (tester) async {
      put();
      await tester.pumpWidget(opener(const AddExpensePage()));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AddExpensePage), findsNothing); // nothing typed: no question

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Groceries');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(S.discardChangesTitle), findsOneWidget);

      await tester.tap(find.text(S.keepEditing));
      await tester.pumpAndSettle();
      expect(find.byType(AddExpensePage), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.discard));
      await tester.pumpAndSettle();
      expect(find.byType(AddExpensePage), findsNothing);
    });

    testWidgets('back is blocked while saving', (tester) async {
      final c = put();
      await tester.pumpWidget(opener(const AddExpensePage()));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      c.saving.value = true;
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pump(const Duration(milliseconds: 500)); // a spinner is running: never "settles"
      expect(find.byType(AddExpensePage), findsOneWidget);
      expect(find.text(S.discardChangesTitle), findsNothing);
    });
  });
}
