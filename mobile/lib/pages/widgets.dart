// Small widgets and dialogs shared by several pages.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app/routes.dart';
import '../app/strings.dart';
import '../app/theme.dart';
import '../domain/money.dart';

/// An amount in minor units, formatted for its currency with tabular figures.
class MoneyText extends StatelessWidget {
  const MoneyText(this.cents, {super.key, required this.currency, this.style, this.signed = false});

  final int cents;
  final String currency;
  final TextStyle? style;

  /// Shows the amount without its sign, colored instead: green when owed to you, red when you owe.
  final bool signed;

  @override
  Widget build(BuildContext context) {
    return Text(
      formatCents(signed ? cents.abs() : cents, currency: currency),
      style: (style ?? const TextStyle()).copyWith(
        color: _color(context),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  Color? _color(BuildContext context) {
    if (!signed || cents == 0) return null;
    final colors = context.moneyColors;
    return cents > 0 ? colors.positive : colors.negative;
  }
}

/// A person's or group's initials on a squircle, the logo's shape. The tint comes from the name,
/// so the same person always gets the same color.
class Initials extends StatelessWidget {
  const Initials(this.name, {super.key, this.radius = 18});

  final String name;

  /// Half the width of the square.
  final double radius;

  // Each tint is (light background, light text, dark background, dark text).
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
    final words = name.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final letters = words.isEmpty ? '?' : words.take(2).map((word) => word.characters.first.toUpperCase()).join();
    final nameSum = name.codeUnits.fold(0, (sum, unit) => sum + unit);
    final tint = _tints[nameSum % _tints.length];
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

/// Grey placeholder rows that pulse while a screen loads. The layout appears at once instead of a
/// lone spinner, and nothing jumps when the data arrives.
class SkeletonList extends StatefulWidget {
  const SkeletonList({super.key, this.count = 5, this.header = false});

  /// How many placeholder rows to show.
  final int count;

  /// Whether to start with a tall card, like the balance card on a group.
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
    Widget box(double width, double height, [double radius = 8]) => Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(
        color: fill,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius)),
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

/// A big bold section heading, matching the headings on the guest web page.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;

  /// Shown at the right end, such as an "add" button.
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

/// A full-page error with a "try again" button, for when a screen's first load fails.
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

/// An error message in a red box, for forms. Shows nothing when [message] is null or empty.
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

/// An empty state that still supports pull-to-refresh, which needs something scrollable underneath.
class ScrollableEmpty extends StatelessWidget {
  const ScrollableEmpty({super.key, required this.child, this.header = const []});

  final Widget child;

  /// Widgets shown above the empty state, such as pending invites.
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

/// The end of a paged list: a spinner while the next page loads, a "load more" button when there are
/// more pages, and nothing at the end. After a failure the list stops loading by itself, so the
/// button is how the user tries again.
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({super.key, required this.hasMore, required this.loading, required this.onLoadMore});

  /// Whether there are more pages.
  final bool hasMore;

  /// Whether the next page is loading.
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

/// The avatar in the home page's app bar. It opens the account page.
class AccountButton extends StatelessWidget {
  const AccountButton({super.key, this.name});

  /// The user's name for the initials. A plain icon shows until it's known.
  final String? name;

  @override
  Widget build(BuildContext context) {
    final name = this.name;
    return IconButton(
      tooltip: S.account,
      onPressed: () => unawaited(Get.toNamed<void>(Routes.account)),
      icon: name == null ? const Icon(Icons.account_circle_outlined) : Initials(name, radius: 15),
    );
  }
}

/// Tells [onCovered] when another page is pushed on top of this one, and [onUncovered] when it's
/// back on top. Dialogs and sheets don't count.
class RouteVisibility extends StatefulWidget {
  const RouteVisibility({super.key, required this.child, this.onCovered, this.onUncovered});

  final Widget child;

  /// Called when another page is pushed on top.
  final VoidCallback? onCovered;

  /// Called when this page is back on top.
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

/// Asks before doing something that can't be undone. Returns whether the user confirmed.
/// [destructive] colors the confirm button red.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = S.cancel,
  bool destructive = true,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(cancelLabel)),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError)
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Shows a message the user has to acknowledge.
Future<void> showMessage(BuildContext context, {required String title, required String message}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(title),
    content: Text(message),
    actions: [FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text(S.ok))],
  ),
);

/// Asks "discard your changes?" before leaving a form with unsaved edits. Returns true to leave.
Future<bool> confirmDiscard(BuildContext context) => confirmAction(
  context,
  title: S.discardChangesTitle,
  message: S.discardChangesBody,
  confirmLabel: S.discard,
  cancelLabel: S.keepEditing,
);

/// Wraps a form page. Blocks the back button and swipe while saving, and asks before throwing away
/// unsaved changes.
class FormPopScope extends StatelessWidget {
  const FormPopScope({super.key, required this.saving, required this.isDirty, required this.child});

  /// Whether a save is running. Read at the moment the user tries to leave.
  final bool Function() saving;

  /// Whether the form has unsaved changes.
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

/// A dialog with one text field, such as "invite by email" or "rename". [onSubmit] returns an error
/// to show under the field, or null to close the dialog.
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

  /// The field's starting text.
  final String initial;

  /// Help text under the field.
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
