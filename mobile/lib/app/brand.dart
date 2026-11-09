// Brand colors and the NetZero logo, drawn in code so it stays sharp at any size and can be
// rendered to the app icon files by tool/brand_assets_test.dart.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// NetZero's brand colors: one bold emerald, near-black ink and a red kept for debts.
abstract final class Brand {
  /// Vivid emerald. White text on it passes WCAG AA (4.5:1).
  static const emerald = Color(0xFF00885A);

  /// The same hue lifted for dark mode, with dark text on it.
  static const emeraldBright = Color(0xFF3DDC97);

  /// Near-black with a hint of green, for text and the "settled" state.
  static const ink = Color(0xFF0E1512);

  /// Accent for "you owe". It is deliberately far from the brand color, so the brand never reads as debt.
  static const red = Color(0xFFE5383B);
}

/// How the mark's background is drawn.
enum MarkShape {
  /// A rounded superellipse square, the in-app logo.
  squircle,

  /// Edge-to-edge square: iOS masks app icons itself.
  fullBleed,

  /// No background: the Android adaptive-icon foreground layer.
  none,
}

/// Paints the NetZero mark: a zero cut along its diagonal into two halves that are nudged apart.
class NetZeroMarkPainter extends CustomPainter {
  const NetZeroMarkPainter({
    this.background = Brand.emerald,
    this.foreground = Colors.white,
    this.shape = MarkShape.squircle,
    this.glyphScale = 1,
  });

  /// Fill behind the symbol.
  final Color background;

  /// Color of the symbol itself.
  final Color foreground;

  /// How the background is drawn.
  final MarkShape shape;

  /// Shrinks the symbol inside the canvas. Android's adaptive icon crops to its centre 66%.
  final double glyphScale;

  // The geometry below is in fractions of the mark's size and matches the SVG on the guest web page.

  /// Outer half-width of the zero. It is an upright oval, so it reads as a digit and not a letter O.
  static const outerRx = 0.25;

  /// Outer half-height of the zero.
  static const outerRy = 0.31;

  /// Thickness of the zero's ring.
  static const thickness = 0.13;

  /// Width of the diagonal cut through the middle.
  static const cutWidth = 0.055;

  /// How far each half slides along the cut, in opposite directions.
  static const slide = 0.035;

  @override
  void paint(Canvas canvas, Size size) {
    final extent = size.shortestSide;
    final rect = Offset.zero & Size.square(extent);
    final fill = Paint()..color = background;
    switch (shape) {
      case MarkShape.squircle:
        canvas.drawRSuperellipse(RSuperellipse.fromRectAndRadius(rect, Radius.circular(extent * 0.3)), fill);
      case MarkShape.fullBleed:
        canvas.drawRect(rect, fill);
      case MarkShape.none:
        break;
    }

    final glyph = extent * glyphScale;
    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCenter(center: Offset.zero, width: glyph * outerRx * 2, height: glyph * outerRy * 2))
      ..addOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: glyph * (outerRx - thickness) * 2,
          height: glyph * (outerRy - thickness) * 2,
        ),
      );
    final paint = Paint()..color = foreground;
    final far = extent * 2;
    final halfCut = glyph * cutWidth / 2;

    // Rotate by -45 degrees so the "/" cut runs along the x axis. Each half is clipped to its side of
    // the cut, slid along it, then rotated back upright.
    for (final side in const [-1.0, 1.0]) {
      final halfPlane = side < 0 ? Rect.fromLTRB(-far, -far, far, -halfCut) : Rect.fromLTRB(-far, halfCut, far, far);
      canvas
        ..save()
        ..translate(rect.center.dx, rect.center.dy)
        ..rotate(-math.pi / 4)
        ..translate(side * glyph * slide, 0)
        ..clipRect(halfPlane)
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

/// The mark on its own, in brand colors that follow the light or dark theme.
class NetZeroMark extends StatelessWidget {
  const NetZeroMark({super.key, this.size = 40});

  /// Width and height in logical pixels.
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

/// The mark followed by the "NetZero" wordmark, for the app bar and the sign-in screen.
class NetZeroLogo extends StatelessWidget {
  const NetZeroLogo({super.key, this.size = 28});

  /// Height of the mark. The wordmark scales with it.
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
