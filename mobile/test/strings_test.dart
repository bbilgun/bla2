import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netzero/app/strings.dart';

void main() {
  test('every error code the server sends has its own Mongolian message', () {
    // Codes from backend/src (AppError calls + lib/http.ts). Generic ones fall back on purpose.
    const specific = [
      'GROUP_NOT_FOUND',
      'USER_NOT_FOUND',
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
      'UNKNOWN_ITEM',
      'CANNOT_REMOVE_HOST',
    ];
    for (final code in specific) {
      expect(S.apiError(code), isNot(S.somethingWentWrong), reason: code);
    }
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
        if (english.hasMatch(code)) offenders.add('$path:${i + 1}: $code');
      }
    }
    expect(offenders, isEmpty, reason: 'Move these to lib/app/strings.dart:\n${offenders.join('\n')}');
  });
}
