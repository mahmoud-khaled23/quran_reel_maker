import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The exact same painter is used in the preview and exported PNG layers.
class AyahPainter extends CustomPainter {
  const AyahPainter({
    this.text,
    this.reference,
    this.attribution = true,
    this.outputSize = canvasSize,
    this.x = 0.5,
    this.y = 0.58,
    this.fontColor = 0xFFFFFFFF,
    this.textBackground = true,
  });
  final Size outputSize;
  final double x, y;
  final int fontColor;
  final bool textBackground;
  final String? text;
  final String? reference;
  final bool attribution;
  static const canvasSize = Size(1080, 1920);
  @override
  void paint(Canvas canvas, Size size) {
    final aspect = outputSize.aspectRatio;
    final logical = Size(
      aspect >= 1 ? 1080 * aspect : 1080,
      aspect >= 1 ? 1080 : 1080 / aspect,
    );
    final textWidth = math.min(1500.0, logical.width * 0.84);
    canvas.save();
    canvas.scale(size.width / logical.width, size.height / logical.height);
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
            color: Color(fontColor),
            shadows: const [Shadow(blurRadius: 4, color: Colors.black)],
          ),
        );
        painter.layout(minWidth: math.min(360, textWidth), maxWidth: textWidth);
        fontSize -= 2;
      } while (painter.height > math.min(760, logical.height * 0.60) &&
          fontSize >= 10);
      final actualWidth = painter.width;
      final boxWidth = actualWidth + 76;
      final boxHeight = painter.height + 112;
      final left = (logical.width * x - boxWidth / 2)
          .clamp(24.0, math.max(24.0, logical.width - boxWidth - 24))
          .toDouble();
      final boxTop = (logical.height * y - boxHeight / 2)
          .clamp(24.0, math.max(24.0, logical.height - boxHeight - 106))
          .toDouble();
      final top = boxTop + 35;
      if (textBackground) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, boxTop, boxWidth, boxHeight),
            const Radius.circular(28),
          ),
          Paint()..color = const Color(0xB8182425),
        );
      }
      painter.paint(canvas, Offset(left + 38, top));
      final textHeight = painter.height;
      painter.dispose();
      _label(
        canvas,
        reference ?? '',
        Offset(left + 38, top + textHeight + 30),
        actualWidth,
        28,
        const Color(0xFFE6CD91),
      );
    }
    if (attribution) {
      _label(
        canvas,
        'Quran text: Tanzil.net · CC BY 3.0',
        Offset(60, logical.height - 70),
        logical.width - 120,
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
    paint(Canvas(recorder), outputSize);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      outputSize.width.round(),
      outputSize.height.round(),
    );
    picture.dispose();
    return image;
  }

  @override
  bool shouldRepaint(covariant AyahPainter oldDelegate) =>
      text != oldDelegate.text ||
      reference != oldDelegate.reference ||
      attribution != oldDelegate.attribution ||
      outputSize != oldDelegate.outputSize ||
      x != oldDelegate.x ||
      y != oldDelegate.y ||
      fontColor != oldDelegate.fontColor ||
      textBackground != oldDelegate.textBackground;
}
