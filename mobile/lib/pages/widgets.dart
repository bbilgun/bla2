import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/routes.dart';
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

/// An empty state that still pulls to refresh: a RefreshIndicator needs something scrollable under it.
class ScrollableEmpty extends StatelessWidget {
  const ScrollableEmpty({super.key, required this.child, this.header = const []});

  final Widget child;

  /// Shown above the empty state (e.g. pending invites).
  final List<Widget> header;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        ...header,
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: header.isEmpty ? constraints.maxHeight * 0.7 : 0),
          child: Center(child: child),
        ),
      ],
    ),
  );
}

/// The end of a paged list: a spinner while the next page loads, a "load more" button when there's
/// more (always shown after a failure, since the list stops loading by itself then), else nothing.
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({super.key, required this.hasMore, required this.loading, required this.onLoadMore});

  final bool hasMore;
  final bool loading;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (!hasMore) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: loading
            ? const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5))
            : TextButton(onPressed: onLoadMore, child: const Text(S.loadMore)),
      ),
    );
  }
}

/// The avatar in the main pages' app bars: opens the profile page (sign out, delete account).
class AccountButton extends StatelessWidget {
  const AccountButton({super.key, this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final n = name;
    return IconButton(
      tooltip: S.account,
      onPressed: () => unawaited(Get.toNamed<void>(Routes.account)),
      icon: n == null ? const Icon(Icons.account_circle_outlined) : Initials(n, radius: 15),
    );
  }
}

/// Tells [onCovered] when another page is pushed on top of this one, and [onUncovered] when it's
/// back on top. Dialogs and sheets don't count.
class RouteVisibility extends StatefulWidget {
  const RouteVisibility({super.key, required this.child, this.onCovered, this.onUncovered});

  final Widget child;
  final VoidCallback? onCovered;
  final VoidCallback? onUncovered;

  @override
  State<RouteVisibility> createState() => _RouteVisibilityState();
}

class _RouteVisibilityState extends State<RouteVisibility> with RouteAware {
  PageRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) routeObserver.unsubscribe(this);
      _route = route;
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() => widget.onCovered?.call();

  @override
  void didPopNext() => widget.onUncovered?.call();

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Asks before doing something that can't be undone. True if confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = S.cancel,
  bool destructive = true,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(cancelLabel)),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError)
              : null,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// A message the person has to acknowledge.
Future<void> showMessage(BuildContext context, {required String title, required String message}) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text(title),
    content: Text(message),
    actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text(S.ok))],
  ),
);

/// "Discard your changes?" when leaving a form with unsaved edits. True to leave.
Future<bool> confirmDiscard(BuildContext context) => confirmAction(
  context,
  title: S.discardChangesTitle,
  message: S.discardChangesBody,
  confirmLabel: S.discard,
  cancelLabel: S.keepEditing,
);

/// Blocks the back button and swipe while [saving], and asks before throwing away unsaved changes.
class FormPopScope extends StatelessWidget {
  const FormPopScope({super.key, required this.saving, required this.isDirty, required this.child});

  final bool Function() saving;
  final bool Function() isDirty;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop || saving()) return;
      if (isDirty() && !await confirmDiscard(context)) return;
      if (context.mounted) Navigator.of(context).pop();
    },
    child: child,
  );
}

/// One text field in a dialog, e.g. "invite by email" or "rename". [onSubmit] returns an error to
/// show under the field, or null to close. Owns (and disposes) its text controller.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    required this.label,
    required this.submitLabel,
    required this.onSubmit,
    this.initial = '',
    this.helper,
    this.keyboardType,
    this.capitalization = TextCapitalization.none,
  });

  final String title;
  final String label;
  final String submitLabel;
  final Future<String?> Function(String value) onSubmit;
  final String initial;
  final String? helper;
  final TextInputType? keyboardType;
  final TextCapitalization capitalization;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final _text = TextEditingController(text: widget.initial);
  String? _error;
  var _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final message = await widget.onSubmit(_text.text);
    if (!mounted) return;
    if (message == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _text,
      autofocus: true,
      keyboardType: widget.keyboardType,
      textCapitalization: widget.capitalization,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helper,
        helperMaxLines: 3,
        errorText: _error,
        errorMaxLines: 3,
      ),
      onSubmitted: (_) => unawaited(_submit()),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text(S.cancel)),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
        onPressed: _saving ? null : () => unawaited(_submit()),
        child: Text(widget.submitLabel),
      ),
    ],
  );
}
