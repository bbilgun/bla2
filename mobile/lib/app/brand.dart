import 'dart:math' as math;

import 'package:flutter/material.dart';

/// NetZero's brand: one bold color, a rounded-square mark with a white geometric symbol cut out of it,
/// heavy type. (Design language inspired by mezorn.com; the symbol and colors are NetZero's own.)
abstract final class Brand {
  /// Vivid emerald. White text on it passes WCAG AA (4.5:1).
  static const emerald = Color(0xFF00885A);

  /// The same hue lifted for dark mode, with dark text on it.
  static const emeraldBright = Color(0xFF3DDC97);

  /// Near-black with a hint of green, for text and the "settled" state.
  static const ink = Color(0xFF0E1512);

  /// Accent for "you owe". Kept apart from the brand color on purpose: in a money app the brand
  /// must never read as debt.
  static const red = Color(0xFFE5383B);
}

/// How the mark's background is drawn.
enum MarkShape {
  /// Rounded square (superellipse), the in-app logo.
  squircle,

  /// Edge-to-edge square: iOS masks app icons itself.
  fullBleed,

  /// No background: the Android adaptive-icon foreground layer.
  none,
}

/// The NetZero mark: a zero split along its diagonal into two halves, nudged apart.
/// "Split it, get back to zero."
class NetZeroMarkPainter extends CustomPainter {
  const NetZeroMarkPainter({
    this.background = Brand.emerald,
    this.foreground = Colors.white,
    this.shape = MarkShape.squircle,
    this.glyphScale = 1,
  });

  final Color background;
  final Color foreground;
  final MarkShape shape;

  /// Shrinks the symbol inside the canvas (Android's adaptive icon crops to its centre 66%).
  final double glyphScale;

  // Geometry as fractions of the mark's size, shared with the SVG in the guest web page.
  /// The zero is an upright oval (a digit, not a letter O): outer half-width and half-height, and ring thickness.
  static const outerRx = 0.25;
  static const outerRy = 0.31;
  static const thickness = 0.13;

  /// The cut: a straight diagonal slash ("/") through the middle, this wide…
  static const cutWidth = 0.055;

  /// …and each half slides this far along the cut, in opposite directions.
  static const slide = 0.035;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final rect = Offset.zero & Size.square(s);
    final fill = Paint()..color = background;
    switch (shape) {
      case MarkShape.squircle:
        canvas.drawRSuperellipse(RSuperellipse.fromRectAndRadius(rect, Radius.circular(s * 0.3)), fill);
      case MarkShape.fullBleed:
        canvas.drawRect(rect, fill);
      case MarkShape.none:
        break;
    }

    final g = s * glyphScale;
    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCenter(center: Offset.zero, width: g * outerRx * 2, height: g * outerRy * 2))
      ..addOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: g * (outerRx - thickness) * 2,
          height: g * (outerRy - thickness) * 2,
        ),
      );
    final paint = Paint()..color = foreground;
    final far = s * 2;
    final cut = g * cutWidth / 2;

    // Work in a frame where the cut runs along x: rotate -45° so "/" becomes horizontal.
    // Each half is clipped to its side of the cut, slid along it, then drawn upright again.
    for (final side in const [-1.0, 1.0]) {
      canvas
        ..save()
        ..translate(rect.center.dx, rect.center.dy)
        ..rotate(-math.pi / 4)
        ..translate(side * g * slide, 0)
        ..clipRect(side < 0 ? Rect.fromLTRB(-far, -far, far, -cut) : Rect.fromLTRB(-far, cut, far, far))
        ..rotate(math.pi / 4)
        ..drawPath(ring, paint)
        ..restore();
    }
  }

  @override
  bool shouldRepaint(NetZeroMarkPainter old) =>
      old.background != background ||
      old.foreground != foreground ||
      old.shape != shape ||
      old.glyphScale != glyphScale;
}

class NetZeroMark extends StatelessWidget {
  const NetZeroMark({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      size: Size.square(size),
      painter: NetZeroMarkPainter(
        background: dark ? Brand.emeraldBright : Brand.emerald,
        foreground: dark ? Brand.ink : Colors.white,
      ),
    );
  }
}

/// Mark + wordmark, for the app bar and the sign-in screen.
class NetZeroLogo extends StatelessWidget {
  const NetZeroLogo({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NetZeroMark(size: size),
        SizedBox(width: size * 0.34),
        Text(
          'NetZero',
          style: TextStyle(
            fontSize: size * 0.78,
            fontWeight: FontWeight.w800,
            letterSpacing: -size * 0.03,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
