import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The exact same painter is used in the preview and exported PNG layers.
class AyahPainter extends CustomPainter {
  const AyahPainter({this.text, this.reference, this.attribution = true});
  final String? text;
  final String? reference;
  final bool attribution;
  static const canvasSize = Size(1080, 1920);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(
      size.width / canvasSize.width,
      size.height / canvasSize.height,
    );
    if (text != null) {
      final painter = TextPainter(
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.center,
        textWidthBasis: TextWidthBasis.parent,
      );
      var fontSize = 76.0;
      do {
        painter.text = TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: 'AmiriQuran',
            fontSize: fontSize,
            height: 1.9,
            color: Colors.white,
          ),
        );
        painter.layout(minWidth: 912, maxWidth: 912);
        fontSize -= 2;
      } while (painter.height > 760 && fontSize >= 10);
      final top = 1110 - painter.height / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(46, top - 35, 988, painter.height + 112),
          const Radius.circular(28),
        ),
        Paint()..color = const Color(0xB8182425),
      );
      painter.paint(canvas, Offset(84, top));
      final textHeight = painter.height;
      painter.dispose();
      _label(
        canvas,
        reference ?? '',
        Offset(84, top + textHeight + 30),
        912,
        28,
        const Color(0xFFE6CD91),
      );
    }
    if (attribution) {
      _label(
        canvas,
        'Quran text: Tanzil.net · CC BY 3.0',
        const Offset(60, 1810),
        960,
        21,
        const Color(0xFFD7DFDC),
      );
    }
    canvas.restore();
  }

  void _label(
    Canvas canvas,
    String value,
    Offset offset,
    double width,
    double size,
    Color color,
  ) {
    final p = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: 'NotoSans',
          fontSize: size,
          color: color,
          shadows: const [Shadow(blurRadius: 4, color: Colors.black)],
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(minWidth: width, maxWidth: width);
    p.paint(canvas, offset);
    p.dispose();
  }

  Future<ui.Image> rasterize() async {
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder), canvasSize);
    final picture = recorder.endRecording();
    final image = await picture.toImage(1080, 1920);
    picture.dispose();
    return image;
  }

  @override
  bool shouldRepaint(covariant AyahPainter oldDelegate) =>
      text != oldDelegate.text ||
      reference != oldDelegate.reference ||
      attribution != oldDelegate.attribution;
}
