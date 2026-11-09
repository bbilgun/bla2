// Entry point: restores the saved session, registers the app-wide services and opens the first screen.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';

import 'app/config.dart';
import 'app/routes.dart';
import 'app/theme.dart';
import 'repositories/repositories.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/cognito_backend.dart';
import 'services/crash_reporting.dart';

/// Starts the app. Signed-in users land on the groups list, everyone else on sign-in.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initCrashReporting();

  if (!AppConfig.isConfigured) {
    runApp(const _MissingConfigApp());
    return;
  }

  // restore() only reads secure storage, so the first screen never waits for the network.
  // Tokens are refreshed by the first request that needs one.
  final cognito = AmazonCognitoBackend(userPoolId: AppConfig.userPoolId, clientId: AppConfig.clientId);
  final auth = await AuthService(cognito).restore();
  Get.put(auth, permanent: true);

  // Services and repositories live for the whole app. Page controllers come from the route bindings.
  final api = Get.put(ApiClient(auth), permanent: true);
  Get.put(UserRepository(api), permanent: true);
  Get.put(GroupsRepository(api), permanent: true);
  Get.put(InvitesRepository(api), permanent: true);
  Get.put(ExpensesRepository(api), permanent: true);
  Get.put(SettlementsRepository(api), permanent: true);
  Get.put(ReceiptsRepository(api), permanent: true);
  Get.put(BillsRepository(api), permanent: true);

  final initialRoute = auth.isSignedIn ? Routes.groups : Routes.signIn;
  runApp(NetZeroApp(initialRoute: initialRoute));
}

/// The root widget: theme, Mongolian locale and the route table.
class NetZeroApp extends StatelessWidget {
  const NetZeroApp({super.key, required this.initialRoute});

  /// The route shown first, decided by whether a session was restored.
  final String initialRoute;

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'NetZero',
      debugShowCheckedModeBanner: false,
      // Flutter's own text, such as tooltips and the copy and paste menu, is Mongolian too.
      locale: const Locale('mn'),
      supportedLocales: const [Locale('mn')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      initialRoute: initialRoute,
      getPages: pages,
      navigatorObservers: [routeObserver],
    );
  }
}

/// Shown instead of the app when it was built without `--dart-define-from-file`.
class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text(
              'NetZero is missing its API config.\n\n'
              'Run with:\nflutter run --dart-define-from-file=env/dev.json\n\n'
              'Create env/dev.json with backend/scripts/stack-outputs.sh dev',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
