import 'dart:math' as math;

import 'dice.dart';

/// How much a roll's unpredictability is counted.
enum EntropyMeasure {
  /// `−log₂ max pᵢ`: what an attacker who always guesses the likeliest face
  /// faces. The conservative measure for keys, and the default.
  min('min-entropy'),

  /// `−Σ pᵢ log₂ pᵢ`: the average surprise. Never below min-entropy; it
  /// overstates what a guesser faces when the die is biased.
  shannon('Shannon entropy');

  const EntropyMeasure(this.label);
  final String label;
}

/// The prior over a die's face probabilities: a symmetric Dirichlet with
/// concentration [alpha] per face. It says how plausible each possible bias
/// is before any roll; the rolls then sharpen it (the posterior).
class Prior {
  const Prior(this.alpha, this.name);

  /// Concentration per face. Below 1 favours badly biased dice, 1 makes every
  /// bias equally plausible, above 1 favours near-fair dice.
  final double alpha;
  final String name;

  /// Jeffreys (0.5): leans towards biased dice — needs the most rolls.
  static const Prior jeffreys = Prior(0.5, 'Jeffreys');

  /// Flat (1): every bias equally plausible. The default.
  static const Prior flat = Prior(1, 'Flat');

  /// Near-fair (10): trusts the die unless the rolls say otherwise.
  static const Prior nearFair = Prior(10, 'Near-fair');

  static const List<Prior> presets = <Prior>[jeffreys, flat, nearFair];
}

/// Monte Carlo draws per estimate: enough to read a probability near 1 % to
/// about ±0.1 %.
const int kDefaultSamples = 20000;

/// Fixed seed of the estimate's random draws, so the same rolls always draw
/// the same curve. The draws are not secret and carry nothing of the rolls.
const int kEstimatorSeed = 0x0D1CE;

/// The settings of an estimate (advanced mode).
class EstimatorSettings {
  const EstimatorSettings({
    this.prior = Prior.flat,
    this.measure = EntropyMeasure.min,
    this.samples = kDefaultSamples,
    this.seed = kEstimatorSeed,
  });

  final Prior prior;
  final EntropyMeasure measure;
  final int samples;
  final int seed;
}

/// A distribution of entropy, in bits, as sorted Monte Carlo samples.
class EntropyDistribution {
  EntropyDistribution(List<double> samples)
      : samples = List<double>.unmodifiable(samples.toList()..sort());

  final List<double> samples;

  /// The [q]-quantile (0 to 1).
  double quantile(double q) {
    if (samples.isEmpty) return 0;
    final double pos = q.clamp(0.0, 1.0) * (samples.length - 1);
    final int lo = pos.floor();
    final int hi = pos.ceil();
    return samples[lo] + (samples[hi] - samples[lo]) * (pos - lo);
  }

  double get median => quantile(0.5);

  double get mean => samples.isEmpty
      ? 0
      : samples.fold<double>(0, (double a, double b) => a + b) /
          samples.length;

  /// The probability that the entropy is below [bits].
  double probabilityBelow(double bits) {
    if (samples.isEmpty) return 1;
    int lo = 0;
    int hi = samples.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (samples[mid] < bits) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo / samples.length;
  }

  /// Sample counts in [bins] equal bins over [from, to); samples outside
  /// fall in the end bins.
  List<int> histogram(double from, double to, int bins) {
    final List<int> out = List<int>.filled(bins, 0);
    final double width = (to - from) / bins;
    for (final double s in samples) {
      final int i = width <= 0 ? 0 : ((s - from) / width).floor();
      out[i.clamp(0, bins - 1)]++;
    }
    return out;
  }
}

/// The entropy of one roll of [die] before any roll: its bias drawn from the
/// prior alone.
EntropyDistribution perRollPrior(Die die,
        [EstimatorSettings settings = const EstimatorSettings()]) =>
    _perRoll(List<int>.filled(die.faces, 0), settings);

/// The entropy of one roll of the die in [rolls] after them: its bias drawn
/// from the posterior.
EntropyDistribution perRollPosterior(DieRolls rolls,
        [EstimatorSettings settings = const EstimatorSettings()]) =>
    _perRoll(rolls.counts, settings);

EntropyDistribution _perRoll(List<int> counts, EstimatorSettings settings) {
  final math.Random rng = math.Random(settings.seed);
  final _Gamma gamma = _Gamma(rng);
  final List<double> p = List<double>.filled(counts.length, 0);
  return EntropyDistribution(<double>[
    for (int s = 0; s < settings.samples; s++)
      _entropy(_dirichlet(counts, settings.prior.alpha, gamma, p),
          settings.measure),
  ]);
}

/// The entropy all of [rolls] carry: for each draw, each die's bias from its
/// posterior, its per-roll entropy times its number of rolls, summed over the
/// dice. Dice are independent; a die without rolls adds nothing.
EntropyDistribution totalEntropy(DiceRolls rolls,
    [EstimatorSettings settings = const EstimatorSettings()]) {
  final math.Random rng = math.Random(settings.seed);
  final _Gamma gamma = _Gamma(rng);
  final List<({List<int> counts, int n, List<double> p})> dice =
      <({List<int> counts, int n, List<double> p})>[
    for (final DieRolls d in rolls.dice)
      if (d.rolls.isNotEmpty)
        (
          counts: d.counts,
          n: d.rolls.length,
          p: List<double>.filled(d.die.faces, 0),
        ),
  ];
  return EntropyDistribution(<double>[
    for (int s = 0; s < settings.samples; s++)
      dice.fold<double>(
        0,
        (double sum, ({List<int> counts, int n, List<double> p}) d) =>
            sum +
            d.n *
                _entropy(_dirichlet(d.counts, settings.prior.alpha, gamma, d.p),
                    settings.measure),
      ),
  ]);
}

/// A draw from Dirichlet(alpha + counts), into [out].
List<double> _dirichlet(
    List<int> counts, double alpha, _Gamma gamma, List<double> out) {
  double sum = 0;
  while (sum <= 0) {
    sum = 0;
    for (int i = 0; i < counts.length; i++) {
      out[i] = gamma.draw(alpha + counts[i]);
      sum += out[i];
    }
  }
  for (int i = 0; i < out.length; i++) {
    out[i] /= sum;
  }
  return out;
}

double _entropy(List<double> p, EntropyMeasure measure) {
  switch (measure) {
    case EntropyMeasure.min:
      return -math.log(p.reduce(math.max)) / math.ln2;
    case EntropyMeasure.shannon:
      double h = 0;
      for (final double x in p) {
        if (x > 0) h -= x * math.log(x) / math.ln2;
      }
      return h;
  }
}

/// Gamma(shape, 1) variates by Marsaglia and Tsang's method ("A simple method
/// for generating gamma variables", ACM TOMS 2000), with normals by the
/// Box–Muller transform.
class _Gamma {
  _Gamma(this._rng);

  final math.Random _rng;
  double? _spare;

  /// Marsaglia–Tsang's constants: `d = a − 1/3`, `c = 1/√(9d)`, and the
  /// squeeze test's coefficient.
  static const double _kThird = 1 / 3;
  static const double _kNine = 9;
  static const double _kSqueeze = 0.0331;

  double draw(double shape) {
    if (shape < 1) {
      // Boost: Gamma(a) = Gamma(a + 1) · U^(1/a).
      return draw(shape + 1) * math.pow(_rng.nextDouble(), 1 / shape);
    }
    final double d = shape - _kThird;
    final double c = 1 / math.sqrt(_kNine * d);
    while (true) {
      double x;
      double v;
      do {
        x = _normal();
        v = 1 + c * x;
      } while (v <= 0);
      v = v * v * v;
      final double u = _rng.nextDouble();
      final double x2 = x * x;
      if (u < 1 - _kSqueeze * x2 * x2) return d * v;
      if (u > 0 && math.log(u) < 0.5 * x2 + d * (1 - v + math.log(v))) {
        return d * v;
      }
    }
  }

  double _normal() {
    final double? s = _spare;
    if (s != null) {
      _spare = null;
      return s;
    }
    double u;
    do {
      u = _rng.nextDouble();
    } while (u <= 0);
    final double r = math.sqrt(-2 * math.log(u));
    final double theta = 2 * math.pi * _rng.nextDouble();
    _spare = r * math.sin(theta);
    return r * math.cos(theta);
  }
}
