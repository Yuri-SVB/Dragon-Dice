// Writes test_vectors/dragon-dice-1.json: rolls, their canonical JSON, its
// SHA-512 and the BIP39 mnemonics of the digest. Run once per format version
// and freeze; `dart test` holds the code to it.
//
//   dart run tool/generate_vectors.dart
import 'dart:convert';
import 'dart:io';

import 'package:dragon_dice/dragon_dice.dart';

void main() {
  final List<DiceRolls> cases = <DiceRolls>[
    DiceRolls(),
    DiceRolls(<DieRolls>[DieRolls(Die(2), <int>[1, 2, 2, 1, 1, 2, 1, 2])]),
    DiceRolls(<DieRolls>[DieRolls(Die(6), <int>[3, 1, 6])]),
    DiceRolls(<DieRolls>[
      DieRolls(Die(20), <int>[1, 2, 3, 4, 5, 6, 7, 8]),
    ]),
    DiceRolls(<DieRolls>[
      DieRolls(Die(6), <int>[3, 1, 6]),
      DieRolls(Die(20), <int>[17, 2]),
    ]),
    DiceRolls(<DieRolls>[
      DieRolls(Die(4), <int>[4, 4, 1]),
      DieRolls(Die(8), <int>[8, 1]),
      DieRolls(Die(10), <int>[10, 1, 5]),
      DieRolls(Die(12), <int>[12, 11]),
      DieRolls(Die(6), <int>[]),
    ]),
    DiceRolls(<DieRolls>[DieRolls(Die(52), <int>[52, 1, 26, 13])]),
    // Peripheral sources: fixed stand-ins for captured digests and bytes.
    DiceRolls(<DieRolls>[DieRolls(Die(20), <int>[20, 1])], <String, String>{
      kSourceMouse: 'ab' * kDigestBytes,
      kSourceRandom: '0f' * kSystemRandomBytes,
    }),
    DiceRolls(<DieRolls>[], <String, String>{
      kSourceRandom: '00' * kSystemRandomBytes,
      kSourceCamera: '11' * kDigestBytes,
      kSourceAccelerometer: '22' * kDigestBytes,
    }),
  ];
  final Map<String, Object> out = <String, Object>{
    'version': kVersion,
    'note': 'SHA-512 of the UTF-8 canonical JSON; BIP39 of its first 128 / '
        '256 bits.',
    'cases': <Map<String, String>>[
      for (final DiceRolls r in cases)
        <String, String>{
          'json': r.canonicalJson(),
          'sha512': _hex(r.digest()),
          'bip39_128': bip39FromDigest(r.digest(), entropyBits: 128),
          'bip39_256': bip39FromDigest(r.digest(), entropyBits: 256),
        },
    ],
  };
  File('test_vectors/dragon-dice-1.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(out)}\n');
}

String _hex(List<int> b) =>
    b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();
