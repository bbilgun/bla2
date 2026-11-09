/// Money in the app is always an `int` number of the currency's minor unit ("cents").
///
/// The app never does money math: the server splits, sums and balances.
/// These functions only convert between what a person types/reads and integer minor units,
/// using integer and string operations only. `double.parse(x) * 100` is banned:
/// double.parse('1.15') * 100 == 114.99999999999999.
///
/// How many minor units a currency has comes from [currencies], the one table every picker and
/// formatter uses: 1 USD = 100 cents, but 1 KRW = 1 won (no decimals), so ₩25,000 is 25000.
library;

/// One currency the app knows how to show.
class CurrencyInfo {
  const CurrencyInfo(this.code, this.symbol, this.digits, {this.symbolAfter = false, this.hideZeroFraction = false});

  /// ISO 4217 code, as the server stores it.
  final String code;
  final String symbol;

  /// Minor-unit digits: 2 for USD (cents), 0 for KRW and JPY.
  final int digits;

  /// Written after the number, the way it's done in Mongolia: "12,500₮".
  final bool symbolAfter;

  /// "42,500₮" rather than "42,500.00₮": tugrik amounts are almost always whole.
  final bool hideZeroFraction;

  /// 10^digits: minor units per major unit.
  int get unit => _pow10(digits);
}

/// Every currency a group or bill can use. The first one is the default.
const currencies = <CurrencyInfo>[
  CurrencyInfo('MNT', '₮', 2, symbolAfter: true, hideZeroFraction: true),
  CurrencyInfo('USD', r'$', 2),
  CurrencyInfo('EUR', '€', 2),
  CurrencyInfo('GBP', '£', 2),
  CurrencyInfo('KRW', '₩', 0),
  CurrencyInfo('JPY', '¥', 0),
  CurrencyInfo('CNY', '¥', 2),
];

/// The codes, for currency pickers.
final currencyCodes = [for (final c in currencies) c.code];

/// The table entry, or a plain 2-digit entry that shows the code ("CHF 12.34") for anything else.
CurrencyInfo currencyInfo(String code) {
  for (final c in currencies) {
    if (c.code == code) return c;
  }
  return CurrencyInfo(code, code, 2);
}

int _pow10(int n) {
  var v = 1;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

// "-25,000.50" / "25000": the whole part is plain digits or groups of three split by commas;
// the fraction (after '.') is checked against the currency's digits below.
final _dotAmount = RegExp(r'^(-)?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?$');
// "7,10" / "0,5": a comma typed as the decimal point (Mongolian and European keyboards).
// Three digits after a comma ("25,000") are a thousands separator instead, matched by [_dotAmount].
final _commaDecimal = RegExp(r'^(-)?(\d+),(\d{1,2})$');
final _spaces = RegExp(r'[\s  ]');

/// Text to an integer amount with [digits] fraction digits, or null.
int? _parseFixed(String input, int digits) {
  final s = input.trim().replaceAll(_spaces, ''); // "25 000"
  final match = _commaDecimal.firstMatch(s) ?? _dotAmount.firstMatch(s);
  if (match == null) return null;
  final whole = match.group(2)!.replaceAll(',', '');
  final frac = match.group(3) ?? '';
  if (whole.length > 13 || frac.length > digits) return null;
  final value = int.parse(whole) * _pow10(digits) + (frac.isEmpty ? 0 : int.parse(frac.padRight(digits, '0')));
  return match.group(1) == null ? value : -value;
}

/// USD: "12.34" -> 1234, "12.3" -> 1230, "12" -> 1200, "0,5" -> 50, "25,000" -> 2500000.
/// KRW: "25,000" -> 25000, "12.5" -> null. Returns null if it isn't an amount.
int? tryParseCents(String input, {String currency = 'USD'}) => _parseFixed(input, currencyInfo(currency).digits);

/// Like [tryParseCents] but throws [FormatException].
int parseCents(String input, {String currency = 'USD'}) {
  final value = tryParseCents(input, currency: currency);
  if (value == null) throw FormatException('Not a money amount', input);
  return value;
}

/// Percent text to basis points: "33.33" -> 3333, "50" -> 5000.
int? tryParseBasisPoints(String input) => _parseFixed(input, 2);

/// "₮", "$", or the code itself ("CHF") when there's no symbol.
String currencySymbol(String currency) => currencyInfo(currency).symbol;

bool symbolAfterAmount(String currency) => currencyInfo(currency).symbolAfter;

/// Whether amounts in [currency] have a fraction part (for the keyboard and hints).
bool hasMinorUnits(String currency) => currencyInfo(currency).digits > 0;

/// What an empty amount field shows: "0.00", or "0" for KRW.
String amountPlaceholder(String currency) => hasMinorUnits(currency) ? '0.00' : '0';

({String whole, String frac}) _split(int abs, CurrencyInfo info) {
  final whole = (abs ~/ info.unit).toString();
  final frac = info.digits == 0 ? '' : (abs % info.unit).toString().padLeft(info.digits, '0');
  return (whole: whole, frac: frac);
}

final _thousands = RegExp(r'\B(?=(\d{3})+(?!\d))');

/// 1234 -> "$12.34", -5 -> "-$0.05", 123456789 -> "$1,234,567.89"; MNT: 1250000 -> "12,500₮",
/// 1234 -> "12.34₮"; KRW: 25000 -> "₩25,000".
String formatCents(int cents, {String currency = 'USD'}) {
  final info = currencyInfo(currency);
  final sign = cents < 0 ? '-' : '';
  final parts = _split(cents.abs(), info);
  final grouped = parts.whole.replaceAllMapped(_thousands, (_) => ',');
  final hideFrac = parts.frac.isEmpty || (info.hideZeroFraction && int.parse(parts.frac) == 0);
  final number = hideFrac ? grouped : '$grouped.${parts.frac}';
  if (info.symbolAfter) return '$sign$number${info.symbol}';
  final known = currencies.any((c) => c.code == currency);
  return '$sign${known ? info.symbol : '${info.symbol} '}$number';
}

/// 1234 -> "12.34" (KRW: 25000 -> "25000"): for pre-filling a text field.
String centsToInput(int cents, {String currency = 'USD'}) {
  final parts = _split(cents.abs(), currencyInfo(currency));
  final sign = cents < 0 ? '-' : '';
  return parts.frac.isEmpty ? '$sign${parts.whole}' : '$sign${parts.whole}.${parts.frac}';
}

/// 3333 -> "33.33": for pre-filling a percent field.
String basisPointsToInput(int bp) =>
    '${bp < 0 ? '-' : ''}${bp.abs() ~/ 100}.${(bp.abs() % 100).toString().padLeft(2, '0')}';

/// 3333 -> "33.33%".
String formatBasisPoints(int bp) => '${basisPointsToInput(bp)}%';
