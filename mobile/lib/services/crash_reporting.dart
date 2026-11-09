// Global error handlers, and Sentry when a DSN is configured.
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../app/config.dart';

/// Prints uncaught errors to the console and, when SENTRY_DSN is set, reports them to Sentry.
///
/// Sentry wraps the handlers installed here and still calls them, so a crash is both printed and reported.
Future<void> initCrashReporting() async {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught: $error\n$stack');
    // Mark it handled so an error nobody awaited doesn't take the app down.
    return true;
  };

  if (AppConfig.sentryDsn.isEmpty) return;
  await SentryFlutter.init((options) {
    options
      ..dsn = AppConfig.sentryDsn
      ..environment = kReleaseMode ? 'production' : 'debug'
      // Amounts and groups are private, so no names, emails or IP addresses.
      ..sendDefaultPii = false;
  });
}
