import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'dice.dart';

/// Peripheral sources: what a capture is credited, its digest, and the
/// system's randomness.
///
/// A capture is a run of readings, each a few integer channels (a mouse: x, y
/// and the time between moves; an accelerometer: x, y, z and the time; a
/// camera: the brightness of a sparse grid of pixels, frame after frame). Only
/// its SHA-512 enters the rolls JSON; the readings are wiped.

/// The z-value of NIST SP 800-90B's 99 % upper confidence bound.
const double _kZ99 = 2.576;

/// Fewer symbols than this get no credit: the estimate needs a sample.
const int kMinSensorSymbols = 64;

/// The symbol alphabet: a byte.
const int _kByteMask = 0xff;

/// Bytes per channel value when a capture is hashed.
const int _kValueBytes = 8;

/// Min-entropy per symbol of [symbols] by the Most Common Value estimate of
/// NIST SP 800-90B (§6.3.1): the likeliest symbol's frequency, raised to its
/// 99 % upper confidence bound, as `−log₂`.
///
/// It assumes independent symbols; sensors are not, which is why captures are
/// reduced to the low byte of each reading's change, channel by channel (see
/// [sensorCredit]) — and why its figure is an estimate, not a guarantee.
double mcvMinEntropy(List<int> symbols) {
  final int n = symbols.length;
  if (n < 2) return 0;
  final Map<int, int> counts = <int, int>{};
  for (final int s in symbols) {
    counts[s] = (counts[s] ?? 0) + 1;
  }
  final double p = counts.values.reduce(math.max) / n;
  final double upper = math.min(1.0, p + _kZ99 * math.sqrt(p * (1 - p) / (n - 1)));
  return -math.log(upper) / math.ln2;
}

/// The credit of a capture, in bits.
typedef SensorCredit = ({double bits, int symbols, double perSymbol});

/// What a capture of [channels] (each channel's readings in time order) is
/// credited: per channel, its symbols — the low byte of each reading's change
/// from the previous one, which strips steady signal and drift — times their
/// [mcvMinEntropy]; summed over the channels. A channel with fewer than
/// [kMinSensorSymbols] symbols gets nothing.
///
/// Each channel is estimated on its own: pooled, two steady channels would
/// pass for a coin. Summing them assumes the channels independent.
SensorCredit sensorCredit(List<List<int>> channels) {
  double bits = 0;
  int symbols = 0;
  for (final List<int> c in channels) {
    final List<int> s = <int>[
      for (int i = 1; i < c.length; i++) (c[i] - c[i - 1]) & _kByteMask,
    ];
    symbols += s.length;
    if (s.length >= kMinSensorSymbols) bits += s.length * mcvMinEntropy(s);
  }
  return (
    bits: bits,
    symbols: symbols,
    perSymbol: symbols == 0 ? 0 : bits / symbols,
  );
}

/// A capture of one peripheral: readings of a fixed number of integer
/// channels, in time order.
class SensorCapture {
  SensorCapture(this.channels)
      : _readings = List<List<int>>.generate(channels, (_) => <int>[]);

  final int channels;
  final List<List<int>> _readings;

  /// Readings taken.
  int get length => _readings.isEmpty ? 0 : _readings.first.length;

  /// Add a reading: one value per channel.
  void add(List<int> reading) {
    if (reading.length != channels) {
      throw ArgumentError('a reading has $channels values');
    }
    for (int c = 0; c < channels; c++) {
      _readings[c].add(reading[c]);
    }
  }

  /// What the capture is credited ([sensorCredit]).
  SensorCredit credit() => sensorCredit(_readings);

  /// SHA-512 of the readings, each value a big-endian 64-bit integer, reading
  /// after reading: what enters the rolls JSON, as lowercase hex.
  String digestHex() {
    final ByteData raw = ByteData(length * channels * _kValueBytes);
    int at = 0;
    for (int r = 0; r < length; r++) {
      for (int c = 0; c < channels; c++) {
        raw.setInt64(at, _readings[c][r]);
        at += _kValueBytes;
      }
    }
    final Uint8List bytes = raw.buffer.asUint8List();
    final String hex = _hex(sha512.convert(bytes).bytes);
    bytes.fillRange(0, bytes.length, 0);
    return hex;
  }

  /// Overwrite the readings and empty them.
  void wipe() {
    for (final List<int> c in _readings) {
      c.fillRange(0, c.length, 0);
      c.clear();
    }
  }
}

/// [kSystemRandomBytes] bytes from the system's secure random generator, as
/// lowercase hex: the backup mixed in under [kSourceRandom], never counted.
String systemRandomHex([math.Random? random]) {
  final math.Random rng = random ?? math.Random.secure();
  final Uint8List bytes = Uint8List(kSystemRandomBytes);
  for (int i = 0; i < bytes.length; i++) {
    bytes[i] = rng.nextInt(_kByteMask + 1);
  }
  final String hex = _hex(bytes);
  bytes.fillRange(0, bytes.length, 0);
  return hex;
}

String _hex(List<int> b) =>
    b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();
