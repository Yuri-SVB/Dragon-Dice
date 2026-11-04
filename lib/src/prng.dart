/// The pseudorandom generator behind the estimate's simulation:
/// xoshiro256** (Blackman and Vigna, "Scrambled linear pseudorandom number
/// generators", 2018), seeded by SplitMix64.
///
/// Pseudorandom on purpose: the simulation needs reproducible, statistically
/// good numbers, not unpredictable ones — it draws plausible dice, not
/// secrets — and must not depend on the system randomness a user of Dragon
/// Dice may not trust. The same seed gives the same numbers everywhere, so the
/// same rolls always draw the same curve. Pinned by vectors (test/).
///
/// Uses 64-bit integer arithmetic that wraps, as on the Dart VM and in AOT
/// builds (not on the web).
class Xoshiro256 {
  /// The generator seeded with [seed]: its four words of state are the first
  /// four outputs of SplitMix64 started at [seed].
  Xoshiro256(int seed) {
    int sm = seed;
    int next() {
      sm += _kGolden;
      int z = sm;
      z = (z ^ (z >>> 30)) * _kMix1;
      z = (z ^ (z >>> 27)) * _kMix2;
      return z ^ (z >>> 31);
    }

    _s0 = next();
    _s1 = next();
    _s2 = next();
    _s3 = next();
  }

  // SplitMix64's constants (Steele, Lea and Flood, 2014).
  static const int _kGolden = 0x9e3779b97f4a7c15;
  static const int _kMix1 = 0xbf58476d1ce4e5b9;
  static const int _kMix2 = 0x94d049bb133111eb;

  // xoshiro256**'s multipliers, rotations and shift.
  static const int _kMul1 = 5;
  static const int _kMul2 = 9;
  static const int _kRot1 = 7;
  static const int _kRot2 = 45;
  static const int _kShift = 17;

  /// Bits of a double's mantissa, and 2⁻⁵³.
  static const int _kMantissa = 53;
  static const double _kUnit = 1.0 / (1 << _kMantissa);

  late int _s0;
  late int _s1;
  late int _s2;
  late int _s3;

  static int _rotl(int x, int k) => (x << k) | (x >>> (64 - k));

  /// The next 64 bits.
  int nextInt64() {
    final int result = _rotl(_s1 * _kMul1, _kRot1) * _kMul2;
    final int t = _s1 << _kShift;
    _s2 ^= _s0;
    _s3 ^= _s1;
    _s1 ^= _s2;
    _s0 ^= _s3;
    _s2 ^= t;
    _s3 = _rotl(_s3, _kRot2);
    return result;
  }

  /// A double in [0, 1): the top 53 bits of [nextInt64].
  double nextDouble() => (nextInt64() >>> (64 - _kMantissa)) * _kUnit;
}
