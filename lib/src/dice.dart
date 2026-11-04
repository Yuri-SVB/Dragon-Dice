import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The standard dice: a coin (D2) to the D20.
const List<int> kStandardFaces = <int>[2, 4, 6, 8, 10, 12, 20];

/// The face counts a custom die may have (advanced mode). A custom die is any
/// fair process with that many equally likely outcomes — say a D52: a card
/// drawn from a well-shuffled deck, put back and shuffled again each time.
const int kMinFaces = 2;
const int kMaxFaces = 1000;

/// The version tag in every rolls JSON: names the format, so a later one can
/// never be mistaken for this one.
const String kVersion = 'dragon-dice/1';

/// The peripheral sources a rolls JSON may mix in, under `"system"`, in key
/// order. Each holds the SHA-512 (hex) of the raw data captured, except
/// [kSourceRandom], which holds the system's random bytes themselves.
const String kSourceAccelerometer = 'accelerometer';
const String kSourceCamera = 'camera';
const String kSourceMouse = 'mouse';
const String kSourceRandom = 'random';
const List<String> kSources = <String>[
  kSourceAccelerometer,
  kSourceCamera,
  kSourceMouse,
  kSourceRandom,
];

/// Bytes of system randomness mixed in: deliberately far more than needed, as
/// a backup that is never counted.
const int kSystemRandomBytes = 1024;

/// Bytes of a SHA-512 digest.
const int kDigestBytes = 64;

/// A die with [faces] equally likely faces, numbered 1 to [faces].
class Die {
  /// A die with [faces] faces, [kMinFaces] to [kMaxFaces]. Throws
  /// [ArgumentError] otherwise.
  Die(this.faces) {
    if (faces < kMinFaces || faces > kMaxFaces) {
      throw ArgumentError.value(faces, 'faces', 'must be $kMinFaces–$kMaxFaces');
    }
  }

  final int faces;

  /// Whether it is one of [kStandardFaces].
  bool get isStandard => kStandardFaces.contains(faces);

  /// `D6`, `D20`, … (`D2` is a coin).
  String get name => 'D$faces';

  /// Bits a roll carries if the die is fair: `log₂ faces`.
  double get fairBits => math.log(faces) / math.ln2;

  /// The roll typed as [text]: a whole number 1 to [faces]; on a D10, whose
  /// faces often read 0–9, 0 stands for 10. Throws [FormatException]
  /// otherwise; the message never echoes the input.
  int parseRoll(String text) {
    final int? v = int.tryParse(text.trim());
    if (faces == _kD10 && v == 0) return _kD10;
    if (v == null || v < 1 || v > faces) {
      throw FormatException('a $name roll is a whole number 1–$faces'
          '${faces == _kD10 ? ' (0 for 10)' : ''}');
    }
    return v;
  }

  @override
  bool operator ==(Object other) => other is Die && other.faces == faces;

  @override
  int get hashCode => faces.hashCode;

  @override
  String toString() => name;
}

const int _kD10 = 10;

/// The rolls of one physical die, in the order rolled.
class DieRolls {
  DieRolls(this.die, [List<int>? rolls]) : rolls = rolls ?? <int>[] {
    for (final int r in this.rolls) {
      _check(r);
    }
  }

  final Die die;
  final List<int> rolls;

  /// Add a roll (1 to the die's faces).
  void add(int roll) {
    _check(roll);
    rolls.add(roll);
  }

  void _check(int roll) {
    if (roll < 1 || roll > die.faces) {
      throw ArgumentError('a ${die.name} roll is 1–${die.faces}');
    }
  }

  /// Bits these rolls carry if the die is fair.
  double get fairBits => rolls.length * die.fairBits;

  /// How many times each face came up (index 0 is face 1).
  List<int> get counts {
    final List<int> c = List<int>.filled(die.faces, 0);
    for (final int r in rolls) {
      c[r - 1]++;
    }
    return c;
  }

  /// Overwrite the rolls and empty the list.
  void wipe() {
    rolls.fillRange(0, rolls.length, 0);
    rolls.clear();
  }
}

/// All the rolls of one entry — one sequence per physical die, in the order
/// the dice were added — and any peripheral sources mixed in. The secret is
/// the SHA-512 of their canonical JSON.
class DiceRolls {
  DiceRolls([List<DieRolls>? dice, Map<String, String>? system])
      : dice = dice ?? <DieRolls>[],
        system = system ?? <String, String>{} {
    this.system.forEach(_checkSource);
  }

  final List<DieRolls> dice;

  /// Peripheral sources by name ([kSources]): lowercase hex, the SHA-512 of
  /// the raw data captured, or for [kSourceRandom] the [kSystemRandomBytes]
  /// random bytes themselves.
  final Map<String, String> system;

  /// Mix in [source] with [hex] (see [system]).
  void setSource(String source, String hex) {
    _checkSource(source, hex);
    system[source] = hex;
  }

  static void _checkSource(String source, String hex) {
    if (!kSources.contains(source)) {
      throw ArgumentError.value(source, 'source', 'must be one of $kSources');
    }
    final int bytes =
        source == kSourceRandom ? kSystemRandomBytes : kDigestBytes;
    if (!RegExp('^[0-9a-f]{${2 * bytes}}\$').hasMatch(hex)) {
      throw ArgumentError('$source is $bytes bytes, in lowercase hex');
    }
  }

  /// How many rolls, over all dice.
  int get rollCount =>
      dice.fold<int>(0, (int n, DieRolls d) => n + d.rolls.length);

  /// Bits the rolls carry if every die is fair.
  double get fairBits =>
      dice.fold<double>(0, (double b, DieRolls d) => b + d.fairBits);

  /// The canonical JSON the digest is taken of: keys sorted, no whitespace,
  /// numbers in decimal, dice in the order added, rolls in the order rolled,
  /// `"system"` only when a source is mixed in. For example:
  ///
  /// `{"dice":[{"faces":6,"rolls":[3,1,6]},{"faces":20,"rolls":[17,2]}],"version":"dragon-dice/1"}`
  ///
  /// Anyone can check a digest with standard tools, e.g.
  /// `printf '%s' '<json>' | sha512sum`.
  String canonicalJson() {
    final StringBuffer out = StringBuffer('{"dice":[');
    for (int i = 0; i < dice.length; i++) {
      if (i > 0) out.write(',');
      out
        ..write('{"faces":')
        ..write(dice[i].die.faces)
        ..write(',"rolls":[')
        ..write(dice[i].rolls.join(','))
        ..write(']}');
    }
    out.write(']');
    if (system.isNotEmpty) {
      out.write(',"system":{');
      bool first = true;
      for (final String source in kSources) {
        final String? hex = system[source];
        if (hex == null) continue;
        if (!first) out.write(',');
        out.write('"$source":"$hex"');
        first = false;
      }
      out.write('}');
    }
    out.write(',"version":"$kVersion"}');
    return out.toString();
  }

  /// SHA-512 of the canonical JSON's UTF-8 bytes.
  Uint8List digest() =>
      Uint8List.fromList(sha512.convert(utf8.encode(canonicalJson())).bytes);

  /// Rolls from decoded JSON in this format (any key order or spacing): the
  /// inverse of [canonicalJson]. Throws [FormatException] on anything else.
  factory DiceRolls.fromJson(Object? json) {
    if (json is! Map<String, Object?> ||
        json['version'] != kVersion ||
        !json.containsKey('dice') ||
        json.keys.any((String k) => !<String>{'dice', 'system', 'version'}.contains(k))) {
      throw const FormatException('not a $kVersion rolls file');
    }
    final Map<String, String> system = <String, String>{};
    if (json.containsKey('system')) {
      final Object? sources = json['system'];
      if (sources is! Map<String, Object?> || sources.isEmpty) {
        throw const FormatException('"system" holds at least one source');
      }
      for (final MapEntry<String, Object?> e in sources.entries) {
        final Object? hex = e.value;
        try {
          if (hex is! String) throw ArgumentError('not hex');
          _checkSource(e.key, hex);
        } on ArgumentError {
          throw FormatException('"system" source ${e.key} is not valid');
        }
        system[e.key] = hex;
      }
    }
    final Object? list = json['dice'];
    if (list is! List<Object?>) {
      throw const FormatException('"dice" must be a list');
    }
    final List<DieRolls> dice = <DieRolls>[];
    for (final Object? d in list) {
      if (d is! Map<String, Object?> || d.length != 2) {
        throw const FormatException('each die is {"faces": n, "rolls": [...]}');
      }
      final Object? faces = d['faces'];
      final Object? rolls = d['rolls'];
      if (faces is! int || rolls is! List<Object?>) {
        throw const FormatException('each die is {"faces": n, "rolls": [...]}');
      }
      final Die die;
      try {
        die = Die(faces);
      } on ArgumentError {
        throw const FormatException('faces must be $kMinFaces–$kMaxFaces');
      }
      final List<int> values = <int>[];
      for (final Object? r in rolls) {
        if (r is! int || r < 1 || r > faces) {
          throw FormatException('a ${die.name} roll is 1–$faces');
        }
        values.add(r);
      }
      dice.add(DieRolls(die, values));
    }
    return DiceRolls(dice, system);
  }

  /// Rolls from JSON text; see [DiceRolls.fromJson].
  factory DiceRolls.parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const FormatException('not JSON');
    }
    return DiceRolls.fromJson(json);
  }

  /// Overwrite every roll and empty the lists and sources. (Strings — the
  /// sources' hex and the JSON built from them — are immutable and cannot be
  /// wiped; they go with the garbage.)
  void wipe() {
    for (final DieRolls d in dice) {
      d.wipe();
    }
    dice.clear();
    system.clear();
  }
}

/// The first [count] bits of [digest], most significant first, as 0s and 1s.
List<int> digestBits(Uint8List digest, int count) {
  if (count < 0 || count > digest.length * 8) {
    throw ArgumentError.value(count, 'count');
  }
  return <int>[
    for (int i = 0; i < count; i++) (digest[i >> 3] >> (7 - (i & 7))) & 1,
  ];
}
