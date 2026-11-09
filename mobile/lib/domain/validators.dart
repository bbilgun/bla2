// Form field validators. They return an error message, or null when the value is fine.
// The server checks the same rules again, so these are only for quick feedback.
import '../app/strings.dart';

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// A loose shape check: something@something.something, ignoring surrounding spaces.
bool isValidEmail(String value) => _emailPattern.hasMatch(value.trim());

/// Validator for email fields.
String? validateEmail(String? value) => value == null || !isValidEmail(value) ? S.enterValidEmail : null;

/// Validator that shows [message] when the field is empty or only spaces.
String? validateRequired(String? value, String message) => (value == null || value.trim().isEmpty) ? message : null;

/// Validator for new passwords, matching the Cognito policy in backend/serverless.yml: at least 10
/// characters with a lowercase letter, an uppercase letter and a digit. The message lists what's missing.
String? validateNewPassword(String? input) {
  final value = input ?? '';
  if (value.length < 10) return S.passwordTooShort;
  final missing = [
    if (!RegExp('[a-z]').hasMatch(value)) S.lowercaseLetter,
    if (!RegExp('[A-Z]').hasMatch(value)) S.uppercaseLetter,
    if (!RegExp(r'\d').hasMatch(value)) S.aDigit,
  ];
  return missing.isEmpty ? null : S.passwordNeeds(missing);
}
