import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netzero/app/strings.dart';

void main() {
  test('every error code the server sends has its own Mongolian message', () {
    // Codes from backend/src (AppError calls + lib/http.ts). Generic ones fall back on purpose.
    const specific = [
      'GROUP_NOT_FOUND',
      'EXPENSE_NOT_FOUND',
      'RECEIPT_NOT_FOUND',
      'PAYER_NOT_MEMBER',
      'SPLIT_USER_NOT_MEMBER',
      'SETTLEMENT_USER_NOT_MEMBER',
      'NOT_A_PARTY',
      'IDEMPOTENCY_KEY_REUSED',
      'VALIDATION_ERROR',
      'INVALID_AMOUNT',
      'SPLIT_EMPTY',
      'SPLIT_DUPLICATE_USER',
      'INVALID_PERCENT',
      'SPLIT_PERCENT_MISMATCH',
      'SPLIT_SUM_MISMATCH',
      'NETWORK',
      'UNAUTHORIZED',
      'BILL_NOT_FOUND',
      'BILL_CLOSED',
      'BILL_FULL',
      'GUEST_NOT_FOUND',
      'CANNOT_REMOVE_HOST',
      // Added with invites, editing and deleting (the API contract, section 7).
      'EXPENSE_CHANGED',
      'SETTLEMENT_NOT_FOUND',
      'BALANCE_NOT_ZERO',
      'BALANCES_NOT_ZERO',
      'INVITE_NOT_FOUND',
      'ALREADY_MEMBER',
      'GROUP_FULL',
      'CANNOT_REMOVE_SELF',
      'MEMBER_NOT_FOUND',
      'INVALID_UPLOAD_KEY',
      'UPLOAD_NOT_FOUND',
      // Raised by the app itself.
      'FILE_TOO_LARGE',
      'UPLOAD_FAILED',
    ];
    for (final code in specific) {
      expect(S.apiError(code), isNot(S.somethingWentWrong), reason: code);
    }
    expect(S.apiError('BILL_CLOSED'), contains(S.reopenBill)); // tells the host what to do
    expect(S.apiError('USER_NOT_FOUND'), S.somethingWentWrong); // removed with invites
    expect(S.apiError('INTERNAL'), S.somethingWentWrong);
    expect(S.apiError('SOMETHING_NEW'), S.somethingWentWrong);
  });

  test('dates read the Mongolian way', () {
    final d = DateTime(2026, 11, 5, 12);
    expect(S.date(d), '11-р сарын 5');
    expect(S.month(d), '11-р сар');
  });

  test('no English user-facing text outside app/strings.dart', () {
    // A string literal that starts with two English words ("Try again", "No groups yet") is UI text
    // that skipped the translation file. Comments and the developer-only missing-config screen are exempt.
    final english = RegExp(r"""['"][A-Z][a-z]+ [a-z]+""");
    const exempt = {'lib/app/strings.dart', 'lib/main.dart'};
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || exempt.contains(path)) continue;
      for (final (i, line) in file.readAsLinesSync().indexed) {
        final code = line.trimLeft();
        if (code.startsWith('//') || code.startsWith('///')) continue;
        if (code.contains('FormatException(')) continue; // developer error, never shown
        if (code.contains('// not UI text')) continue; // e.g. a library's own error code
        if (english.hasMatch(code)) offenders.add('$path:${i + 1}: $code');
      }
    }
    expect(offenders, isEmpty, reason: 'Move these to lib/app/strings.dart:\n${offenders.join('\n')}');
  });
}
