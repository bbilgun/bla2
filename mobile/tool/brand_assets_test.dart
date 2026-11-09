// Renders the brand mark (lib/app/brand.dart) to the PNGs the app icon and the QR code use.
// Run after changing the mark:
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
      // iOS: edge to edge, the system rounds the corners.
      await _export('assets/brand/icon.png', const NetZeroMarkPainter(shape: MarkShape.fullBleed), 1024);
      // Android adaptive icon: symbol only, small enough for the launcher's centre-crop.
      await _export(
        'assets/brand/icon-foreground.png',
        const NetZeroMarkPainter(shape: MarkShape.none, glyphScale: 0.62),
        1024,
      );
      // In-app use (the centre of the bill QR code).
      await _export('assets/brand/mark.png', const NetZeroMarkPainter(), 256);
    });
    expect(File('assets/brand/icon.png').existsSync(), isTrue);
  });
}
