/// Form checks that run before anything is sent. The server checks the same things again.
library;

import '../app/strings.dart';

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

bool isValidEmail(String value) => _emailPattern.hasMatch(value.trim());

String? validateEmail(String? v) => v == null || !isValidEmail(v) ? S.enterValidEmail : null;

String? validateRequired(String? v, String message) => (v == null || v.trim().isEmpty) ? message : null;

/// The Cognito password policy (backend serverless.yml): at least 10 characters with a lowercase
/// letter, an uppercase letter and a number. Checked here so the person sees what's missing
/// before Cognito says no.
String? validateNewPassword(String? v) {
  final value = v ?? '';
  if (value.length < 10) return S.passwordTooShort;
  final missing = [
    if (!RegExp('[a-z]').hasMatch(value)) S.lowercaseLetter,
    if (!RegExp('[A-Z]').hasMatch(value)) S.uppercaseLetter,
    if (!RegExp(r'\d').hasMatch(value)) S.aDigit,
  ];
  return missing.isEmpty ? null : S.passwordNeeds(missing);
}
