import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../app/config.dart';

/// Uncaught errors go to the console always, and to Sentry when SENTRY_DSN is set.
///
/// The handlers are installed either way. Sentry, when it starts, wraps them (it calls the previous
/// handler too), so a crash is printed locally and reported.
Future<void> initCrashReporting() async {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught: $error\n$stack');
    return true; // handled: don't crash the app over an error nobody awaited
  };

  if (AppConfig.sentryDsn.isEmpty) return;
  await SentryFlutter.init((options) {
    options
      ..dsn = AppConfig.sentryDsn
      ..environment = kReleaseMode ? 'production' : 'debug'
      // No names, emails or IPs: amounts and groups are private.
      ..sendDefaultPii = false;
  });
}
