// Converting money between what people type or read and integer minor units ("cents").
// Amounts are always ints and the parsing never goes through double. docs/mobile.md explains why.

/// How the app shows one currency.
class CurrencyInfo {
  const CurrencyInfo(this.code, this.symbol, this.digits, {this.symbolAfter = false, this.hideZeroFraction = false});

  /// ISO 4217 code, as the server stores it.
  final String code;

  /// Symbol shown next to amounts, such as "₮". Currencies outside the table use their code.
  final String symbol;

  /// Digits after the decimal point: 2 for USD, 0 for KRW and JPY.
  final int digits;

  /// Whether the symbol goes after the number, as in Mongolia: "12,500₮".
  final bool symbolAfter;

  /// Whether to drop a fraction of zero, so tugrik shows "42,500₮" rather than "42,500.00₮".
  final bool hideZeroFraction;

  /// Minor units per major unit, 10 to the power of [digits].
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

/// The currency codes in table order, for pickers.
final currencyCodes = [for (final currency in currencies) currency.code];

/// The table entry for [code]. Unknown codes get two decimals and show the code, as in "CHF 12.34".
CurrencyInfo currencyInfo(String code) {
  for (final currency in currencies) {
    if (currency.code == code) return currency;
  }
  return CurrencyInfo(code, code, 2);
}

int _pow10(int exponent) {
  var result = 1;
  for (var i = 0; i < exponent; i++) {
    result *= 10;
  }
  return result;
}

// Matches "-25,000.50" or "25000": plain digits or comma-separated thousands, then an optional
// fraction after a dot. The fraction length is checked against the currency below.
final _dotAmount = RegExp(r'^(-)?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?$');
// Matches "7,10" or "0,5", where a Mongolian or European keyboard put a comma as the decimal point.
// Three digits after a comma ("25,000") are thousands instead, and _dotAmount handles those.
final _commaDecimal = RegExp(r'^(-)?(\d+),(\d{1,2})$');
final _spaces = RegExp(r'[\s  ]');

// Parses text into an int scaled by 10^digits, or returns null.
int? _parseFixed(String input, int digits) {
  // Spaces are allowed as thousands separators: "25 000".
  final text = input.trim().replaceAll(_spaces, '');
  final match = _commaDecimal.firstMatch(text) ?? _dotAmount.firstMatch(text);
  if (match == null) return null;
  final whole = match.group(2)!.replaceAll(',', '');
  final fraction = match.group(3) ?? '';
  if (whole.length > 13 || fraction.length > digits) return null;
  final fractionUnits = fraction.isEmpty ? 0 : int.parse(fraction.padRight(digits, '0'));
  final value = int.parse(whole) * _pow10(digits) + fractionUnits;
  final isNegative = match.group(1) != null;
  return isNegative ? -value : value;
}

/// Parses an amount the user typed into minor units, or returns null if it isn't one.
/// For USD, "12.3" gives 1230 and "0,5" gives 50. For KRW, which has no decimals, "12.5" gives null.
int? tryParseCents(String input, {String currency = 'USD'}) => _parseFixed(input, currencyInfo(currency).digits);

/// Like [tryParseCents], but throws a [FormatException] when the text isn't an amount.
int parseCents(String input, {String currency = 'USD'}) {
  final value = tryParseCents(input, currency: currency);
  if (value == null) throw FormatException('Not a money amount', input);
  return value;
}

/// Parses a percentage into basis points, so "33.33" gives 3333. Returns null if it isn't one.
int? tryParseBasisPoints(String input) => _parseFixed(input, 2);

/// The currency's symbol, or its code when the app has no symbol for it.
String currencySymbol(String currency) => currencyInfo(currency).symbol;

/// Whether the symbol is written after the number.
bool symbolAfterAmount(String currency) => currencyInfo(currency).symbolAfter;

/// Whether amounts in [currency] have a fraction part. Decides the keyboard type and hints.
bool hasMinorUnits(String currency) => currencyInfo(currency).digits > 0;

/// Hint text for an empty amount field: "0.00", or "0" for currencies without decimals.
String amountPlaceholder(String currency) => hasMinorUnits(currency) ? '0.00' : '0';

({String whole, String fraction}) _split(int absolute, CurrencyInfo info) {
  final whole = (absolute ~/ info.unit).toString();
  final fraction = info.digits == 0 ? '' : (absolute % info.unit).toString().padLeft(info.digits, '0');
  return (whole: whole, fraction: fraction);
}

// Matches each position that needs a thousands comma.
final _thousands = RegExp(r'\B(?=(\d{3})+(?!\d))');

/// Formats minor units for display with the currency symbol and thousands separators.
/// For example 123456789 USD is "$1,234,567.89", 1250000 MNT is "12,500₮" and 25000 KRW is "₩25,000".
String formatCents(int cents, {String currency = 'USD'}) {
  final info = currencyInfo(currency);
  final sign = cents < 0 ? '-' : '';
  final parts = _split(cents.abs(), info);
  final grouped = parts.whole.replaceAllMapped(_thousands, (_) => ',');
  final hideFraction = parts.fraction.isEmpty || (info.hideZeroFraction && int.parse(parts.fraction) == 0);
  final number = hideFraction ? grouped : '$grouped.${parts.fraction}';
  if (info.symbolAfter) return '$sign$number${info.symbol}';
  // A currency outside the table shows its code, which needs a space before the number.
  final isKnown = currencies.any((known) => known.code == currency);
  final prefix = isKnown ? info.symbol : '${info.symbol} ';
  return '$sign$prefix$number';
}

/// Minor units as plain text for pre-filling an amount field, so 1234 USD is "12.34".
String centsToInput(int cents, {String currency = 'USD'}) {
  final parts = _split(cents.abs(), currencyInfo(currency));
  final sign = cents < 0 ? '-' : '';
  if (parts.fraction.isEmpty) return '$sign${parts.whole}';
  return '$sign${parts.whole}.${parts.fraction}';
}

/// Basis points as plain text for pre-filling a percent field, so 3333 is "33.33".
String basisPointsToInput(int basisPoints) {
  final sign = basisPoints < 0 ? '-' : '';
  final whole = basisPoints.abs() ~/ 100;
  final hundredths = (basisPoints.abs() % 100).toString().padLeft(2, '0');
  return '$sign$whole.$hundredths';
}

/// Basis points as a percentage for display, so 3333 is "33.33%".
String formatBasisPoints(int basisPoints) => '${basisPointsToInput(basisPoints)}%';
