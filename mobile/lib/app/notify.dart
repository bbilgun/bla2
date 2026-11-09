// Snackbar messages for controllers, which have no BuildContext.
import 'package:get/get.dart';

/// Shows a short message at the bottom of the screen.
typedef Notifier = void Function(String title, String message);

/// The function [notify] calls. Tests replace it with a recorder, because a real snackbar needs a
/// running app with an overlay.
Notifier notifier = (title, message) => Get.snackbar(title, message, snackPosition: SnackPosition.BOTTOM);

/// Shows [title] to the user, with [message] underneath if given.
void notify(String title, [String message = '']) => notifier(title, message);
