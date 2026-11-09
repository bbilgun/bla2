import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';

import 'app/config.dart';
import 'app/routes.dart';
import 'app/theme.dart';
import 'repositories/repositories.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!AppConfig.isConfigured) {
    runApp(const _MissingConfigApp());
    return;
  }

  // App-wide singletons. Page controllers come from route bindings (app/routes.dart).
  final auth = await Get.putAsync(() => AuthService().init(), permanent: true);
  final api = Get.put(ApiClient(auth), permanent: true);
  Get
    ..put(UserRepository(api), permanent: true)
    ..put(GroupsRepository(api), permanent: true)
    ..put(ExpensesRepository(api), permanent: true)
    ..put(SettlementsRepository(api), permanent: true)
    ..put(ReceiptsRepository(api), permanent: true)
    ..put(BillsRepository(api), permanent: true);

  runApp(NetZeroApp(initialRoute: auth.isSignedIn.value ? Routes.groups : Routes.signIn));
}

class NetZeroApp extends StatelessWidget {
  const NetZeroApp({super.key, required this.initialRoute});

  final String initialRoute;

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'NetZero',
      debugShowCheckedModeBanner: false,
      // Mongolian everywhere: our text (app/strings.dart) and Flutter's own (back buttons, copy/paste, dialogs).
      locale: const Locale('mn'),
      supportedLocales: const [Locale('mn')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      initialRoute: initialRoute,
      getPages: pages,
    );
  }
}

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
