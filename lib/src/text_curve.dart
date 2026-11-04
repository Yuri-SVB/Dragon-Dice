import 'estimator.dart';

/// Block characters from empty to full, for a one-line curve.
const List<String> _kBlocks = <String>[' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];

/// Columns of a text curve.
const int kTextCurveWidth = 60;

/// How far past the larger of the target and the top sample the axis runs.
const double _kAxisHeadroom = 1.15;

/// The quantile the axis must reach, so a long thin tail does not squash the
/// curve.
const double _kAxisQuantile = 0.999;

/// [d] as a two-line text curve: the histogram as block characters, then an
/// axis with the [target] marked `┼` and its scale.
String textCurve(EntropyDistribution d, double target,
    {int width = kTextCurveWidth}) {
  final double top = (d.quantile(_kAxisQuantile) > target
          ? d.quantile(_kAxisQuantile)
          : target) *
      _kAxisHeadroom;
  final List<int> bins = d.histogram(0, top, width);
  final int peak = bins.fold<int>(0, (int a, int b) => b > a ? b : a);
  final StringBuffer curve = StringBuffer();
  for (final int n in bins) {
    final int level =
        peak == 0 ? 0 : (n * (_kBlocks.length - 1) / peak).ceil();
    curve.write(_kBlocks[level]);
  }
  final int mark = (target / top * width).floor().clamp(0, width - 1);
  final String axis =
      '${'─' * mark}┼${'─' * (width - mark - 1)}';
  final String scale = '0${' ' * (mark - 1 < 0 ? 0 : mark - 1)}'
      '${target.toStringAsFixed(0)}'
      '${' ' * (width - mark - target.toStringAsFixed(0).length).clamp(0, width)}'
      '${top.toStringAsFixed(0)} bits';
  return '$curve\n$axis\n$scale';
}
