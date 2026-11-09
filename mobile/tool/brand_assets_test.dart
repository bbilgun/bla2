// Renders the mark from lib/app/brand.dart to the PNGs used for the app icon and the bill QR code.
// Run it after changing the mark:
//   flutter test tool/brand_assets_test.dart && dart run flutter_launcher_icons
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netzero/app/brand.dart';

Future<void> _export(String path, CustomPainter painter, int size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), Size.square(size.toDouble()));
  final image = await recorder.endRecording().toImage(size, size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  testWidgets('export brand PNGs', (tester) async {
    await tester.runAsync(() async {
      // iOS draws the icon edge to edge and rounds the corners itself.
      await _export('assets/brand/icon.png', const NetZeroMarkPainter(shape: MarkShape.fullBleed), 1024);
      // Android's adaptive icon gets the symbol alone, small enough to survive the launcher's crop.
      await _export(
        'assets/brand/icon-foreground.png',
        const NetZeroMarkPainter(shape: MarkShape.none, glyphScale: 0.62),
        1024,
      );
      // The logo in the middle of the bill QR code.
      await _export('assets/brand/mark.png', const NetZeroMarkPainter(), 256);
    });
    expect(File('assets/brand/icon.png').existsSync(), isTrue);
  });
}
