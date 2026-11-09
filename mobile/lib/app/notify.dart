import 'package:get/get.dart';

/// Shows a short message at the bottom of the screen.
typedef Notifier = void Function(String title, String message);

/// Controllers call [notify] instead of `Get.snackbar` directly. Tests swap [notifier] for a recorder:
/// a real snackbar needs a running app with an overlay.
Notifier notifier = (title, message) => Get.snackbar(title, message, snackPosition: SnackPosition.BOTTOM);

void notify(String title, [String message = '']) => notifier(title, message);
