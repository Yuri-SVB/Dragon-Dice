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

/// The format tag in every rolls JSON: names the format, so a later one can
/// never be mistaken for this one.
const String kFormat = 'dragon-dice/1';

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

/// All the rolls of one entry: one sequence per physical die, in the order
/// the dice were added. The secret is the SHA-512 of their canonical JSON.
class DiceRolls {
  DiceRolls([List<DieRolls>? dice]) : dice = dice ?? <DieRolls>[];

  final List<DieRolls> dice;

  /// How many rolls, over all dice.
  int get rollCount =>
      dice.fold<int>(0, (int n, DieRolls d) => n + d.rolls.length);

  /// Bits the rolls carry if every die is fair.
  double get fairBits =>
      dice.fold<double>(0, (double b, DieRolls d) => b + d.fairBits);

  /// The canonical JSON the digest is taken of: keys sorted, no whitespace,
  /// numbers in decimal, dice in the order added, rolls in the order rolled.
  /// For example:
  ///
  /// `{"dice":[{"faces":6,"rolls":[3,1,6]},{"faces":20,"rolls":[17,2]}],"format":"dragon-dice/1"}`
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
    out.write('],"format":"$kFormat"}');
    return out.toString();
  }

  /// SHA-512 of the canonical JSON's UTF-8 bytes.
  Uint8List digest() =>
      Uint8List.fromList(sha512.convert(utf8.encode(canonicalJson())).bytes);

  /// Rolls from decoded JSON in this format (any key order or spacing): the
  /// inverse of [canonicalJson]. Throws [FormatException] on anything else.
  factory DiceRolls.fromJson(Object? json) {
    if (json is! Map<String, Object?> ||
        json.length != 2 ||
        json['format'] != kFormat) {
      throw const FormatException('not a $kFormat rolls file');
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
    return DiceRolls(dice);
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

  /// Overwrite every roll and empty the lists. (The JSON strings built from
  /// them are immutable and cannot be wiped; they go with the garbage.)
  void wipe() {
    for (final DieRolls d in dice) {
      d.wipe();
    }
    dice.clear();
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
