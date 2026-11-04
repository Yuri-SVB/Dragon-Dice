import 'dart:math' as math;

import 'package:dragon_dice/dragon_dice.dart';
import 'package:flutter/material.dart';

/// Bins of a chart's curve.
const int kChartBins = 80;

/// How far past the larger of the target and the curve's top the axis runs.
const double _kHeadroom = 1.15;

/// The quantile the axis must reach, so a thin tail does not squash the
/// curve.
const double _kTopQuantile = 0.999;

/// A distribution of entropy drawn as a curve over a bits axis, with a
/// [target] marked and the part of the curve below it shaded as a warning.
/// An optional [reference] (say the prior) is drawn as an outline behind.
class EntropyChart extends StatelessWidget {
  const EntropyChart({
    super.key,
    required this.distribution,
    this.target,
    this.reference,
    this.marker,
    this.height = 160,
  });

  final EntropyDistribution distribution;

  /// The target in bits, marked and shaded below; null for none.
  final double? target;

  /// A second distribution drawn as an outline (e.g. the prior).
  final EntropyDistribution? reference;

  /// A value marked with a thin line (e.g. a fair die's entropy).
  final double? marker;
  final double height;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ChartPainter(
          distribution: distribution,
          target: target,
          reference: reference,
          marker: marker,
          curve: theme.colorScheme.primary,
          warn: theme.colorScheme.error,
          axis: theme.colorScheme.outline,
          text: theme.textTheme.bodySmall ?? const TextStyle(fontSize: 11),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.distribution,
    required this.target,
    required this.reference,
    required this.marker,
    required this.curve,
    required this.warn,
    required this.axis,
    required this.text,
  });

  final EntropyDistribution distribution;
  final double? target;
  final EntropyDistribution? reference;
  final double? marker;
  final Color curve;
  final Color warn;
  final Color axis;
  final TextStyle text;

  /// Room under the axis for its labels, in logical pixels.
  static const double _kLabelRoom = 16;
  static const double _kStroke = 1.5;
  static const double _kFillAlpha = 0.25;

  @override
  void paint(Canvas canvas, Size size) {
    final double plotH = size.height - _kLabelRoom;
    final double top = <double>[
          distribution.quantile(_kTopQuantile),
          reference?.quantile(_kTopQuantile) ?? 0,
          target ?? 0,
          marker ?? 0,
          1,
        ].reduce(math.max) *
        _kHeadroom;
    double x(double bits) => bits / top * size.width;

    Path shape(EntropyDistribution d) {
      final List<int> bins = d.histogram(0, top, kChartBins);
      final int peak = bins.reduce(math.max);
      final double binW = size.width / kChartBins;
      final Path p = Path()..moveTo(0, plotH);
      for (int i = 0; i < kChartBins; i++) {
        final double h = peak == 0 ? 0 : bins[i] / peak * plotH;
        p.lineTo((i + 0.5) * binW, plotH - h);
      }
      p
        ..lineTo(size.width, plotH)
        ..close();
      return p;
    }

    final EntropyDistribution? ref = reference;
    if (ref != null && ref.samples.isNotEmpty) {
      canvas.drawPath(
        shape(ref),
        Paint()
          ..color = axis
          ..style = PaintingStyle.stroke
          ..strokeWidth = _kStroke,
      );
    }
    if (distribution.samples.isNotEmpty) {
      final Path main = shape(distribution);
      canvas.drawPath(main, Paint()..color = curve.withValues(alpha: _kFillAlpha));
      final double? t = target;
      if (t != null) {
        // The part of the curve short of the target.
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, x(t), plotH));
        canvas.drawPath(main, Paint()..color = warn.withValues(alpha: 2 * _kFillAlpha));
        canvas.restore();
      }
      canvas.drawPath(
        main,
        Paint()
          ..color = curve
          ..style = PaintingStyle.stroke
          ..strokeWidth = _kStroke,
      );
    }
    final Paint axisPaint = Paint()
      ..color = axis
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, plotH), Offset(size.width, plotH), axisPaint);
    void label(String s, double at, {bool right = false}) {
      final TextPainter tp = TextPainter(
        text: TextSpan(text: s, style: text),
        textDirection: TextDirection.ltr,
      )..layout();
      final double left = right ? at - tp.width : at - tp.width / 2;
      tp.paint(canvas, Offset(left.clamp(0, size.width - tp.width), plotH + 2));
    }

    label('0', 0);
    label('${top.toStringAsFixed(0)} bits', size.width, right: true);
    final double? m = marker;
    if (m != null) {
      canvas.drawLine(Offset(x(m), 0), Offset(x(m), plotH), axisPaint);
    }
    final double? t = target;
    if (t != null) {
      canvas.drawLine(
        Offset(x(t), 0),
        Offset(x(t), plotH),
        Paint()
          ..color = warn
          ..strokeWidth = 2,
      );
      label(t.toStringAsFixed(0), x(t));
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.distribution != distribution ||
      old.reference != reference ||
      old.target != target ||
      old.marker != marker ||
      old.curve != curve;
}
