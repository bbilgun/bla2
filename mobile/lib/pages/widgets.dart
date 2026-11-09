import 'package:flutter/material.dart';

import '../app/strings.dart';
import '../app/theme.dart';
import '../domain/money.dart';

/// Formats integer cents. Colors by sign when [signed] is set: green owed to you, red you owe.
class MoneyText extends StatelessWidget {
  const MoneyText(this.cents, {super.key, required this.currency, this.style, this.signed = false});

  final int cents;
  final String currency;
  final TextStyle? style;
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final colors = context.moneyColors;
    final color = !signed || cents == 0 ? null : (cents > 0 ? colors.positive : colors.negative);
    return Text(
      formatCents(signed ? cents.abs() : cents, currency: currency),
      style: (style ?? const TextStyle()).copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
    );
  }
}

/// A person's or group's initials on a squircle (the logo's shape), tinted by name so the same
/// person always gets the same color.
class Initials extends StatelessWidget {
  const Initials(this.name, {super.key, this.radius = 18});

  final String name;
  final double radius;

  // (light background, light text, dark background, dark text)
  static const _tints = [
    (Color(0xFFDDF5EA), Color(0xFF00573A), Color(0xFF123526), Color(0xFF7BE3B5)),
    (Color(0xFFE2ECFF), Color(0xFF1F4BB8), Color(0xFF16233F), Color(0xFF9EBBFF)),
    (Color(0xFFFFF0D6), Color(0xFF8A5300), Color(0xFF33270F), Color(0xFFF7C46C)),
    (Color(0xFFF0E6FF), Color(0xFF5B2DB3), Color(0xFF261A3D), Color(0xFFC6A8FF)),
    (Color(0xFFFFE6E6), Color(0xFFA3262A), Color(0xFF3B1516), Color(0xFFFFA3A5)),
    (Color(0xFFDDF3F7), Color(0xFF0A6475), Color(0xFF102E34), Color(0xFF85D6E5)),
  ];

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final letters = parts.isEmpty ? '?' : parts.take(2).map((p) => p.characters.first.toUpperCase()).join();
    final tint = _tints[name.codeUnits.fold(0, (a, c) => a + c) % _tints.length];
    final dark = Theme.of(context).brightness == Brightness.dark;
    final size = radius * 2;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: dark ? tint.$3 : tint.$1,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(size * 0.32)),
      ),
      child: Text(
        letters,
        style: TextStyle(fontSize: radius * 0.72, fontWeight: FontWeight.w800, color: dark ? tint.$4 : tint.$2),
      ),
    );
  }
}

/// Grey placeholder shapes that pulse while a screen loads: the layout appears at once instead of
/// a lone spinner, and nothing jumps when the data arrives. One animation drives all of them.
class SkeletonList extends StatefulWidget {
  const SkeletonList({super.key, this.count = 5, this.header = false});

  final int count;

  /// A tall card first, like the balance card on a group.
  final bool header;

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fill = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget box(double w, double h, [double r = 8]) => Container(
      width: w,
      height: h,
      decoration: ShapeDecoration(
        color: fill,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(r)),
      ),
    );
    final row = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            box(40, 40, 13),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [box(140, 14), const SizedBox(height: 8), box(90, 12)],
              ),
            ),
            box(56, 14),
          ],
        ),
      ),
    );
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          if (widget.header) ...[box(double.infinity, 168, 28), const SizedBox(height: 16)],
          for (var i = 0; i < widget.count; i++) ...[row, const SizedBox(height: 10)],
        ],
      ),
    );
  }
}

/// Big bold section title, like the headings on the guest page.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Row(
      children: [
        Expanded(child: Text(text, style: Theme.of(context).textTheme.titleLarge)),
        ?trailing,
      ],
    ),
  );
}

class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 40, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text(S.tryAgain)),
          ],
        ),
      ),
    );
  }
}

class InlineError extends StatelessWidget {
  const InlineError(this.message, {super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
      child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
    );
  }
}

/// "11-р сарын 5"
String shortDate(DateTime d) => S.date(d);
