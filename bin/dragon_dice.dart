// Dragon Dice in the terminal: roll real dice, type the rolls, get the
// SHA-512 digest of their canonical JSON and its BIP39 mnemonic.
//
//   dart run dragon_dice              roll interactively (BIP39, 24 words)
//   dart run dragon_dice --help       all options
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dragon_dice/dragon_dice.dart';

const String _kUsage = '''
Dragon Dice — entropy from real dice that anyone can audit.

Usage:
  dragon_dice [options]               roll interactively, then print the
                                      digest and its BIP39 words
  dragon_dice bip39 [options] [FILE]  BIP39 words of a rolls JSON FILE, or
                                      of a SHA-512 digest typed (hidden)
  dragon_dice hash FILE               SHA-512 of a rolls JSON FILE

Options:
  --words N      BIP39 words: 12, 15, 18, 21 or 24 (default 24); the target
                 is their entropy (128 to 256 bits)
  --target BITS  entropy target in bits, instead of the words'
  --show         echo rolls as typed (default: hidden)
  --system       also mix in $kSystemRandomBytes bytes of system randomness: a
                 backup, never counted toward the target
  --save FILE    also write the rolls JSON to FILE — it IS the secret
  --advanced     the Bayesian estimate: rolls are ready when the chance of
                 carrying less than the target is at most --bound. Its curve
                 is computed from your secret rolls: use it in private.
  --prior P      jeffreys | flat | near-fair | a number (default flat)
  --measure M    min | shannon (default min)
  --bound P      highest acceptable chance of falling short (default 0.01)
  --samples N    simulation samples (default 100 / bound)
  -h, --help     this help

Advanced mode also takes custom dice: d52 for a card drawn from a
well-shuffled deck and put back, d3 for a D6 read 1-2/3-4/5-6, and so on.
See doc/ADVANCED.md.''';

/// Exit codes.
const int _kOk = 0;
const int _kDeclined = 2;
const int _kUsageError = 64;
const int _kDataError = 65;
const int _kCancelled = 1;

/// Default BIP39 words.
const int _kDefaultWords = 24;

class _Options {
  int words = _kDefaultWords;
  double? target;
  bool show = false;
  bool system = false;
  String? save;
  bool advanced = false;
  Prior prior = Prior.flat;
  EntropyMeasure measure = EntropyMeasure.min;
  double bound = kDefaultBound;
  int? samples;
  final List<String> rest = <String>[];

  int get entropyBits => kBip39EntropyBits[_kWordCounts.indexOf(words)];
  double get targetBits => target ?? entropyBits.toDouble();
  EstimatorSettings get settings => EstimatorSettings(
        prior: prior,
        measure: measure,
        samples: samples ?? samplesForBound(bound),
      );
}

final List<int> _kWordCounts = <int>[
  for (final int b in kBip39EntropyBits) bip39Words(b),
];

void main(List<String> args) {
  final _Options o;
  try {
    o = _parse(args);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$_kUsage');
    exit(_kUsageError);
  }
  if (o.rest.isNotEmpty && o.rest.first == 'help') {
    stdout.writeln(_kUsage);
    return;
  }
  try {
    exit(switch (o.rest.isEmpty ? '' : o.rest.first) {
      '' => _interactive(o),
      'bip39' => _bip39(o),
      'hash' => _hash(o),
      _ => throw FormatException('unknown command ${o.rest.first}'),
    });
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(_kDataError);
  }
}

_Options _parse(List<String> args) {
  final _Options o = _Options();
  String value(Iterator<String> it, String name) {
    if (!it.moveNext()) throw FormatException('$name needs a value');
    return it.current;
  }

  final Iterator<String> it = args.iterator;
  while (it.moveNext()) {
    final String a = it.current;
    switch (a) {
      case '-h' || '--help':
        o.rest
          ..clear()
          ..add('help');
        return o;
      case '--words':
        final int? w = int.tryParse(value(it, a));
        if (w == null || !_kWordCounts.contains(w)) {
          throw FormatException('--words is one of $_kWordCounts');
        }
        o.words = w;
      case '--target':
        final double? t = double.tryParse(value(it, a));
        if (t == null || t <= 0) throw const FormatException('--target is bits');
        o.target = t;
      case '--show':
        o.show = true;
      case '--system':
        o.system = true;
      case '--save':
        o.save = value(it, a);
      case '--advanced':
        o.advanced = true;
      case '--prior':
        final String p = value(it, a);
        o.prior = switch (p) {
          'jeffreys' => Prior.jeffreys,
          'flat' => Prior.flat,
          'near-fair' => Prior.nearFair,
          _ => () {
              final double? alpha = double.tryParse(p);
              if (alpha == null || alpha <= 0) {
                throw const FormatException('--prior: jeffreys, flat, near-fair or α > 0');
              }
              return Prior(alpha, 'α = $p');
            }(),
        };
      case '--measure':
        o.measure = switch (value(it, a)) {
          'min' => EntropyMeasure.min,
          'shannon' => EntropyMeasure.shannon,
          _ => throw const FormatException('--measure: min or shannon'),
        };
      case '--bound':
        final double? b = double.tryParse(value(it, a));
        if (b == null || b <= 0 || b >= 1) {
          throw const FormatException('--bound is a probability between 0 and 1');
        }
        o.bound = b;
      case '--samples':
        final int? n = int.tryParse(value(it, a));
        if (n == null || n < 100) throw const FormatException('--samples ≥ 100');
        o.samples = n;
      default:
        if (a.startsWith('-')) throw FormatException('unknown option $a');
        o.rest.add(a);
    }
  }
  return o;
}

// --- commands ----------------------------------------------------------------

int _hash(_Options o) {
  if (o.rest.length != 2) throw const FormatException('hash takes one FILE');
  final DiceRolls rolls = DiceRolls.parse(File(o.rest[1]).readAsStringSync());
  stdout.writeln(_hex(rolls.digest()));
  rolls.wipe();
  return _kOk;
}

int _bip39(_Options o) {
  final Uint8List digest;
  if (o.rest.length == 2) {
    final DiceRolls rolls = DiceRolls.parse(File(o.rest[1]).readAsStringSync());
    _report(rolls, o);
    digest = rolls.digest();
    rolls.wipe();
  } else if (o.rest.length == 1) {
    stdout.write('SHA-512 digest (128 hex digits, hidden): ');
    final String hex = _readHidden(o.show).trim();
    stdout.writeln();
    if (!RegExp(r'^[0-9a-fA-F]{128}$').hasMatch(hex)) {
      throw const FormatException('a SHA-512 digest is 128 hex digits');
    }
    digest = _unhex(hex);
  } else {
    throw const FormatException('bip39 takes at most one FILE');
  }
  _printSecret(<String>[
    'BIP39 (${o.words} words):',
    bip39FromDigest(digest, entropyBits: o.entropyBits),
  ]);
  digest.fillRange(0, digest.length, 0);
  return _kOk;
}

/// The acknowledgement advanced mode asks for: its curve and figures are
/// computed from the secret rolls, so whoever sees them learns about the
/// rolls.
bool _acknowledgeAdvanced() {
  stdout.write('''
  !!! ADVANCED MODE SHOWS WHAT YOUR ROLLS LOOK LIKE !!!
  Its curve, median and chances are computed from your secret rolls: anyone
  who sees this screen, or a recording of it, learns something about them.
  Use it only where no one and no camera can see. Type YES to go on: ''');
  return (stdin.readLineSync()?.trim() ?? '') == 'YES';
}

int _interactive(_Options o) {
  if (o.advanced && !_acknowledgeAdvanced()) return _kDeclined;
  final DiceRolls rolls = DiceRolls();
  stdout.writeln('''
Dragon Dice — target ${o.targetBits.toStringAsFixed(0)} bits (${o.words} BIP39 words)${o.advanced ? ', advanced' : ''}${o.system ? ', with system randomness (not counted)' : ''}.

  d6, d20, …  start a die (each one you start is another physical die)
  3 1 6       its rolls, as they come (hidden; ${o.show ? 'shown' : 'add --show to see them'})
  undo        drop the last roll
  Enter       done          quit   leave without output
Dice: ${kStandardFaces.map((int f) => 'd$f').join(' ')}${o.advanced ? ', or any dN ($kMinFaces–$kMaxFaces)' : ''}.''');
  DieRolls? current;
  while (true) {
    stdout.write(current == null ? 'die> ' : '${current.die.name}> ');
    final String line = _readHidden(o.show).trim().toLowerCase();
    if (!o.show) stdout.writeln();
    if (line == 'quit') {
      rolls.wipe();
      return _kCancelled;
    }
    if (line.isEmpty) {
      if (_finish(rolls, o)) break;
      continue;
    }
    if (line == 'undo') {
      if (current != null && current.rolls.isNotEmpty) {
        current.rolls.removeLast();
      }
      _report(rolls, o);
      continue;
    }
    final RegExpMatch? die = RegExp(r'^d(\d+)$').firstMatch(line);
    if (die != null) {
      final int faces = int.parse(die.group(1)!);
      if (!o.advanced && !kStandardFaces.contains(faces)) {
        stdout.writeln('Custom dice need --advanced.');
        continue;
      }
      try {
        current = DieRolls(Die(faces));
        rolls.dice.add(current);
      } on ArgumentError {
        stdout.writeln('A die has $kMinFaces–$kMaxFaces faces.');
      }
      continue;
    }
    if (current == null) {
      stdout.writeln('Start a die first, e.g. d20.');
      continue;
    }
    final List<String> parts = line.split(RegExp(r'[\s,]+'));
    final List<int> parsed = <int>[];
    try {
      for (final String p in parts) {
        parsed.add(current.die.parseRoll(p));
      }
    } on FormatException catch (e) {
      stdout.writeln('${e.message} — that line was not added.');
      continue;
    }
    parsed.forEach(current.add);
    _report(rolls, o, added: parsed.length);
  }
  if (o.system) rolls.setSource(kSourceRandom, systemRandomHex());
  final Uint8List digest = rolls.digest();
  final String? save = o.save;
  if (save != null) {
    File(save).writeAsStringSync('${rolls.canonicalJson()}\n');
    stdout.writeln('Rolls written to $save — that file IS the secret.');
  }
  _printSecret(<String>[
    'SHA-512 of the rolls:',
    _hex(digest),
    '',
    'BIP39 (${o.words} words):',
    bip39FromDigest(digest, entropyBits: o.entropyBits),
  ]);
  digest.fillRange(0, digest.length, 0);
  rolls.wipe();
  return _kOk;
}

/// Whether the rolls may be finished now: at once if they reach the target,
/// else after an emphatic warning the user confirms.
bool _finish(DiceRolls rolls, _Options o) {
  final double target = o.targetBits;
  final String? shortfall;
  if (o.advanced) {
    final double p = totalEntropy(rolls, o.settings).probabilityBelow(target);
    shortfall = p <= o.bound
        ? null
        : 'there is a ${_pct(p)} chance these rolls carry less than '
            '${target.toStringAsFixed(0)} bits (your bound: ${_pct(o.bound)}).';
  } else {
    shortfall = rolls.fairBits >= target
        ? null
        : 'even from fair dice these rolls carry only '
            '${rolls.fairBits.toStringAsFixed(1)} of '
            '${target.toStringAsFixed(0)} bits.';
  }
  if (shortfall == null) return true;
  stdout.write('''

  !!! NOT ENOUGH ENTROPY !!!
  ${shortfall[0].toUpperCase()}${shortfall.substring(1)}
  A key from them is weaker than it looks, and this tool bears no
  responsibility for it. Roll more, or type YES to finish anyway: ''');
  final String answer = stdin.readLineSync()?.trim() ?? '';
  return answer == 'YES';
}

void _report(DiceRolls rolls, _Options o, {int added = 0}) {
  final String dice = rolls.dice
      .map((DieRolls d) => '${d.die.name}×${d.rolls.length}')
      .join(' ');
  stdout.writeln('${added > 0 ? '+$added  ' : ''}$dice  —  '
      '${rolls.fairBits.toStringAsFixed(1)} of '
      '${o.targetBits.toStringAsFixed(0)} bits if fair');
  if (!o.advanced || rolls.rollCount == 0) return;
  final EntropyDistribution d = totalEntropy(rolls, o.settings);
  stdout.writeln(textCurve(d, o.targetBits));
  stdout.writeln('median ${d.median.toStringAsFixed(1)} bits · '
      'chance below target ${_pct(d.probabilityBelow(o.targetBits))} '
      '(bound ${_pct(o.bound)}) · ${o.prior.name} prior, ${o.measure.label}');
}

void _printSecret(List<String> lines) {
  stdout.writeln('''

================================ SECRET =================================''');
  lines.forEach(stdout.writeln);
  stdout.writeln('''
=========================================================================
Write it down offline, then clear this terminal and its scrollback.''');
}

/// A line from stdin, echoed only if [show] (and stdin is a terminal).
String _readHidden(bool show) {
  final bool hide = !show && stdin.hasTerminal;
  if (hide) stdin.echoMode = false;
  try {
    return stdin.readLineSync(encoding: utf8) ?? 'quit';
  } finally {
    if (hide) stdin.echoMode = true;
  }
}

String _pct(double p) => '${(p * 100).toStringAsFixed(p < 0.1 ? 2 : 1)} %';

String _hex(List<int> b) =>
    b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String h) => Uint8List.fromList(<int>[
      for (int i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16),
    ]);
