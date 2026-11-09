/// Money in the app is always an `int` number of cents.
///
/// The app never does money math: the server splits, sums and balances.
/// These two functions only convert between what a person types/reads and integer cents,
/// using integer and string operations only. `double.parse(x) * 100` is banned:
/// double.parse('1.15') * 100 == 114.99999999999999.
library;

final _amountPattern = RegExp(r'^(-)?(\d{1,13})(?:[.,](\d{1,2}))?$');

/// "12.34" -> 1234, "12.3" -> 1230, "12" -> 1200, "0,5" -> 50. Returns null if it isn't an amount.
int? tryParseCents(String input) {
  final match = _amountPattern.firstMatch(input.trim().replaceAll(' ', ''));
  if (match == null) return null;
  final whole = int.parse(match.group(2)!);
  final frac = int.parse((match.group(3) ?? '').padRight(2, '0'));
  final value = whole * 100 + frac;
  return match.group(1) == null ? value : -value;
}

/// Like [tryParseCents] but throws [FormatException].
int parseCents(String input) {
  final value = tryParseCents(input);
  if (value == null) throw FormatException('Not a money amount', input);
  return value;
}

/// Percent text to basis points: "33.33" -> 3333, "50" -> 5000. Same rules as cents.
int? tryParseBasisPoints(String input) => tryParseCents(input);

const _symbols = {'USD': r'$', 'EUR': '€', 'GBP': '£', 'MNT': '₮', 'KRW': '₩', 'CNY': '¥', 'JPY': '¥'};

/// Currencies written with the symbol after the number, the way it's done in Mongolia: "12,500.00₮".
const _symbolAfter = {'MNT'};

/// "₮", "$", or the code itself ("CHF") when there's no symbol.
String currencySymbol(String currency) => _symbols[currency] ?? currency;

bool symbolAfterAmount(String currency) => _symbolAfter.contains(currency);

/// 1234 -> "$12.34", -5 -> "-$0.05", 123456789 -> "$1,234,567.89"; MNT: 1250000 -> "12,500₮", 1234 -> "12.34₮".
String formatCents(int cents, {String currency = 'USD'}) {
  final sign = cents < 0 ? '-' : '';
  final abs = cents.abs();
  final whole = (abs ~/ 100).toString();
  final frac = (abs % 100).toString().padLeft(2, '0');
  final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  if (symbolAfterAmount(currency)) {
    // Tugrik amounts are almost always whole: "42,500₮" reads better than "42,500.00₮".
    return '$sign$grouped${frac == '00' ? '' : '.$frac'}${currencySymbol(currency)}';
  }
  final symbol = _symbols[currency] ?? '$currency ';
  return '$sign$symbol$grouped.$frac';
}

/// 1234 -> "12.34": for pre-filling a text field.
String centsToInput(int cents) {
  final abs = cents.abs();
  return '${cents < 0 ? '-' : ''}${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}

/// 3333 -> "33.33%".
String formatBasisPoints(int bp) => '${bp ~/ 100}.${(bp % 100).toString().padLeft(2, '0')}%';
