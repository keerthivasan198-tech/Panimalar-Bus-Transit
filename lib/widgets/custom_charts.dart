import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class LineChartPainter extends CustomPainter {
  final List<double> dataPoints;
  final List<String> labels;
  LineChartPainter(this.dataPoints, this.labels);

  @override
  void paint(Canvas canvas, Size size) {
    if (dataPoints.isEmpty) return;
    
    final paintLine = Paint()
      ..color = const Color(0xFF2563EB)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final paintFill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [const Color(0xFF2563EB).withValues(alpha: 0.3), const Color(0xFF2563EB).withValues(alpha: 0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    final path = ui.Path();
    final fillPath = ui.Path();

    double dx = size.width / (dataPoints.length - 1);
    double maxVal = 10.0;

    for (int i = 0; i < dataPoints.length; i++) {
      double py = size.height - (dataPoints[i] / maxVal) * size.height;
      double px = i * dx;
      if (i == 0) {
        path.moveTo(px, py);
        fillPath.moveTo(px, size.height);
        fillPath.lineTo(px, py);
      } else {
        path.lineTo(px, py);
        fillPath.lineTo(px, py);
      }
      if (i == dataPoints.length - 1) {
        fillPath.lineTo(px, size.height);
        fillPath.close();
      }
    }
    
    canvas.drawPath(fillPath, paintFill);
    canvas.drawPath(path, paintLine);

    final paintDot = Paint()..color = const Color(0xFF2563EB);
    for (int i = 0; i < dataPoints.length; i++) {
      double py = size.height - (dataPoints[i] / maxVal) * size.height;
      double px = i * dx;
      canvas.drawCircle(Offset(px, py), 4, paintDot);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class DoughnutChartPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  DoughnutChartPainter(this.values, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    double total = values.fold(0, (a, b) => a + b);
    if (total == 0) return;

    double startAngle = -pi / 2;
    double strokeWidth = 24.0;
    Rect rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (min(size.width, size.height) - strokeWidth) / 2,
    );

    for (int i = 0; i < values.length; i++) {
      double sweepAngle = (values[i] / total) * 2 * pi;
      final paint = Paint()
        ..color = colors[i]
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(rect, startAngle + 0.05, sweepAngle - 0.1, false, paint);
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class BarChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final Color barColor;
  BarChartPainter(this.values, this.labels, this.barColor);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    
    double maxVal = 20.0;
    double numBars = values.length.toDouble();
    double spacing = 12.0;
    double barWidth = (size.width - (spacing * (numBars + 1))) / numBars;
    
    final paintBar = Paint()
      ..color = barColor
      ..style = PaintingStyle.fill;
      
    final paintGrid = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      double y = size.height * (i / 4.0);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paintGrid);
    }

    for (int i = 0; i < values.length; i++) {
      double h = (values[i] / maxVal) * size.height;
      double x = spacing + i * (barWidth + spacing);
      double y = size.height - h;
      
      RRect rrect = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, y, barWidth, h),
        topLeft: const Radius.circular(6),
        topRight: const Radius.circular(6),
      );
      canvas.drawRRect(rrect, paintBar);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
