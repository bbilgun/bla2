import 'package:flutter_test/flutter_test.dart';
import 'package:netzero/domain/money.dart';

void main() {
  group('kata', () {
    test('formatCents(1234) == "\$12.34"', () => expect(formatCents(1234), r'$12.34'));
    test('parseCents("12.34") == 1234', () => expect(parseCents('12.34'), 1234));
  });

  group('why not double.parse(x) * 100', () {
    test('floats drift', () {
      expect(double.parse('1.15') * 100, isNot(115));
      expect(parseCents('1.15'), 115);
    });
  });

  group('tryParseCents', () {
    final cases = {
      '12.34': 1234,
      '12.3': 1230,
      '12': 1200,
      '0.05': 5,
      ' 7.10 ': 710,
      '7,10': 710, // comma decimal keyboards
      '-3.50': -350,
      '1 000.00': 100000,
    };
    cases.forEach((input, expected) {
      test('"$input" -> $expected', () => expect(tryParseCents(input), expected));
    });

    for (final bad in ['', '.', '1.234', 'abc', '1e3', '12.', r'$5']) {
      test('rejects "$bad"', () => expect(tryParseCents(bad), isNull));
    }
  });

  group('formatCents', () {
    test('signs and grouping', () {
      expect(formatCents(5), r'$0.05');
      expect(formatCents(0), r'$0.00');
      expect(formatCents(-350), r'-$3.50');
      expect(formatCents(123456789), r'$1,234,567.89');
    });

    test('currencies', () {
      expect(formatCents(1234, currency: 'MNT'), '12.34₮');
      expect(formatCents(1250000, currency: 'MNT'), '12,500₮');
      expect(formatCents(-50, currency: 'MNT'), '-0.50₮');
      expect(formatCents(1234, currency: 'CHF'), 'CHF 12.34');
    });

    test('round-trips', () {
      for (final n in [0, 1, 99, 100, 101, 999999]) {
        expect(parseCents(centsToInput(n)), n);
      }
    });
  });

  test('basis points', () {
    expect(tryParseBasisPoints('33.33'), 3333);
    expect(tryParseBasisPoints('50'), 5000);
    expect(formatBasisPoints(3334), '33.34%');
  });
}
