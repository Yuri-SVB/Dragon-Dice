import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'dice.dart';

/// Peripheral sources: what a capture is credited, its digest, and the
/// system's randomness.
///
/// A capture is a run of readings, each a few integer channels (a mouse: x, y
/// and the time of each move; an accelerometer: x, y, z and the time; a
/// camera: the brightness of a sparse grid of pixels and the time, frame after
/// frame). Only its SHA-512 enters the rolls JSON; the readings are wiped.

/// The z-value of NIST SP 800-90B's 99 % upper confidence bound.
const double _kZ99 = 2.576;

/// Fewer symbols than this get no credit: the estimate needs a sample.
const int kMinSensorSymbols = 64;

/// The most a reading is credited, in bits: one per move, however varied the
/// readings look. Informal estimates put a mouse position at a bit or two
/// (Keybase's more-entropy); the readings of a hand, a body or a scene are
/// correlated in ways no test on the readings alone can rule out.
const double kMaxBitsPerReading = 1;

/// A reading closer than this to the last counted one, in microseconds, is
/// not counted (about 30 a second): a hand's choices change over tens of
/// milliseconds, so closer readings repeat them, and a fast-polling device
/// earns no more than a slow one. The per-reading estimates the cap rests on
/// were taken at 30 to 60 a second (X41, 2025).
const int kMinReadingIntervalUs = 33000;

/// The symbol alphabet: a byte.
const int _kByteMask = 0xff;

/// Bytes per channel value when a capture is hashed.
const int _kValueBytes = 8;

/// Min-entropy per symbol of [symbols] by the Most Common Value estimate of
/// NIST SP 800-90B (§6.3.1): the likeliest symbol's frequency, raised to its
/// 99 % upper confidence bound, as `−log₂`.
///
/// It assumes independent symbols; sensors are not, which is why a capture's
/// credit is capped ([sensorCredit]) — and why its figure is an estimate, not
/// a guarantee.
double mcvMinEntropy(List<Object> symbols) {
  final int n = symbols.length;
  if (n < 2) return 0;
  final Map<Object, int> counts = <Object, int>{};
  for (final Object s in symbols) {
    counts[s] = (counts[s] ?? 0) + 1;
  }
  final double p = counts.values.reduce(math.max) / n;
  final double upper = math.min(1.0, p + _kZ99 * math.sqrt(p * (1 - p) / (n - 1)));
  return -math.log(upper) / math.ln2;
}

/// The credit of a capture, in bits.
typedef SensorCredit = ({double bits, int symbols, double perSymbol});

/// What a capture of [channels] (each channel's readings in time order) is
/// credited: at most [kMaxBitsPerReading] per reading counted.
///
/// - **Counted readings:** with a [timeChannel] (microseconds), at most one
///   per [kMinReadingIntervalUs]; and only once some value has moved by at
///   least [minStep] since the last counted reading, so that small wiggles
///   and repeated frames do not count. The time itself is never credited: it
///   mostly shows the device's polling.
/// - **One symbol per reading:** how it departs from the previous move — the
///   second difference of each other channel, its low byte — all channels
///   together. A steady motion or a still scene gives one symbol, so nothing.
/// - **Credit:** the symbols' [mcvMinEntropy], capped at
///   [kMaxBitsPerReading], times their number; nothing below
///   [kMinSensorSymbols] symbols.
SensorCredit sensorCredit(
  List<List<int>> channels, {
  int? timeChannel,
  int minStep = 0,
}) {
  final int n = channels.isEmpty ? 0 : channels.first.length;
  final List<int> counted = <int>[];
  for (int r = 0; r < n; r++) {
    if (counted.isNotEmpty) {
      final int last = counted.last;
      if (timeChannel != null &&
          channels[timeChannel][r] - channels[timeChannel][last] <
              kMinReadingIntervalUs) {
        continue;
      }
      int moved = 0;
      for (int c = 0; c < channels.length; c++) {
        if (c != timeChannel) {
          moved = math.max(moved, (channels[c][r] - channels[c][last]).abs());
        }
      }
      if (moved < minStep) continue;
    }
    counted.add(r);
  }
  // A second difference spans three readings.
  const int span = 2;
  final List<String> symbols = <String>[
    for (int k = span; k < counted.length; k++)
      <int>[
        for (int c = 0; c < channels.length; c++)
          if (c != timeChannel)
            (channels[c][counted[k]] -
                    2 * channels[c][counted[k - 1]] +
                    channels[c][counted[k - 2]]) &
                _kByteMask,
      ].join(','),
  ];
  final double perSymbol = symbols.length < kMinSensorSymbols
      ? 0
      : math.min(kMaxBitsPerReading, mcvMinEntropy(symbols));
  return (
    bits: perSymbol * symbols.length,
    symbols: symbols.length,
    perSymbol: perSymbol,
  );
}

/// A capture of one peripheral: readings of a fixed number of integer
/// channels, in time order; [timeChannel], if any, holds each reading's time
/// in microseconds.
class SensorCapture {
  SensorCapture(this.channels, {this.timeChannel, this.minStep = 0})
      : _readings = List<List<int>>.generate(channels, (_) => <int>[]);

  final int channels;
  final int? timeChannel;

  /// The move a reading needs, in its values' units, to be counted
  /// ([sensorCredit]).
  final int minStep;
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
  SensorCredit credit() => sensorCredit(
        _readings,
        timeChannel: timeChannel,
        minStep: minStep,
      );

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
