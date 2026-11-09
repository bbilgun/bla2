// The Material theme for light and dark mode, plus the colors used for money amounts.
import 'package:flutter/material.dart';

import 'brand.dart';

/// Colors for money amounts, carried on the theme so they switch with dark mode.
class MoneyColors extends ThemeExtension<MoneyColors> {
  const MoneyColors({required this.positive, required this.negative});

  /// Money owed to you.
  final Color positive;

  /// Money you owe.
  final Color negative;

  @override
  MoneyColors copyWith({Color? positive, Color? negative}) =>
      MoneyColors(positive: positive ?? this.positive, negative: negative ?? this.negative);

  @override
  MoneyColors lerp(MoneyColors? other, double t) {
    if (other == null) {
      return this;
    }
    return MoneyColors(
      positive: Color.lerp(positive, other.positive, t)!,
      negative: Color.lerp(negative, other.negative, t)!,
    );
  }
}

/// Builds the app theme: flat white cards on a soft grey ground, hairline borders instead of shadows,
/// superellipse corners to match the logo, and heavy headings.
ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final primary = dark ? Brand.emeraldBright : Brand.emerald;
  final onPrimary = dark ? Brand.ink : Colors.white;
  final scheme = ColorScheme.fromSeed(seedColor: Brand.emerald, brightness: brightness).copyWith(
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: dark ? const Color(0xFF123526) : const Color(0xFFDDF5EA),
    onPrimaryContainer: dark ? Brand.emeraldBright : const Color(0xFF00573A),
    surface: dark ? const Color(0xFF0B0F0D) : const Color(0xFFF4F6F5),
    onSurface: dark ? const Color(0xFFE8EEEB) : Brand.ink,
    onSurfaceVariant: dark ? const Color(0xFF9DB0A6) : const Color(0xFF5B6B62),
    surfaceContainerLowest: dark ? const Color(0xFF0E1311) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF141A17) : Colors.white,
    surfaceContainer: dark ? const Color(0xFF18201C) : const Color(0xFFF0F3F1),
    surfaceContainerHigh: dark ? const Color(0xFF1D2622) : const Color(0xFFEBEFED),
    surfaceContainerHighest: dark ? const Color(0xFF253029) : const Color(0xFFE2E8E5),
    outline: dark ? const Color(0xFF3A4741) : const Color(0xFFC5CFCA),
    outlineVariant: dark ? const Color(0xFF243029) : const Color(0xFFE2E8E5),
    error: dark ? const Color(0xFFFF8A8C) : Brand.red,
    onError: dark ? Brand.ink : Colors.white,
    errorContainer: dark ? const Color(0xFF3B1516) : const Color(0xFFFDE7E7),
    onErrorContainer: dark ? const Color(0xFFFFB3B4) : const Color(0xFF8C1D1F),
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  // base.textTheme has fonts and colors but no sizes until Theme.of fills them in, and the styles below
  // go straight to the app bar, dialogs and buttons. Merging in the Material 3 type scale gives them sizes.
  final scale = Typography.englishLike2021.merge(base.textTheme);
  final text = scale
      .copyWith(
        displaySmall: scale.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1.2),
        headlineMedium: scale.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8),
        headlineSmall: scale.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        titleLarge: scale.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
        titleMedium: scale.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        titleSmall: scale.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        labelLarge: scale.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      )
      .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

  RoundedSuperellipseBorder shape(double radius, {BorderSide side = BorderSide.none}) =>
      RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius), side: side);
  OutlineInputBorder field([Color? color, double width = 1.5]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(16),
    borderSide: color == null ? BorderSide.none : BorderSide(color: color, width: width),
  );
  final buttonText = text.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w700);

  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
      shape: shape(24, side: BorderSide(color: scheme.outlineVariant)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: field(),
      enabledBorder: field(),
      disabledBorder: field(),
      focusedBorder: field(primary, 2),
      errorBorder: field(scheme.error),
      focusedErrorBorder: field(scheme.error, 2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54), shape: shape(18), textStyle: buttonText),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 54),
        shape: shape(18),
        side: BorderSide(color: scheme.outline),
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(textStyle: buttonText)),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: onPrimary,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: shape(20),
      extendedTextStyle: buttonText,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: shape(14),
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelMedium?.copyWith(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
          color: states.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: shape(14),
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: scheme.onPrimaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: text.labelLarge,
      ),
    ),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: shape(28),
      titleTextStyle: text.titleLarge,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: shape(16, side: BorderSide(color: scheme.outlineVariant)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: scheme.surfaceContainerHighest,
    ),
    extensions: [
      MoneyColors(
        positive: dark ? Brand.emeraldBright : Brand.emerald,
        negative: dark ? const Color(0xFFFF8A8C) : Brand.red,
      ),
    ],
  );
}

/// Shortcut for `Theme.of(context).extension<MoneyColors>()`.
extension MoneyColorsX on BuildContext {
  /// The money colors of the current theme.
  MoneyColors get moneyColors => Theme.of(this).extension<MoneyColors>()!;
}
