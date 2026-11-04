import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dragon_dice/dragon_dice.dart';
import 'package:test/test.dart';

Uint8List _hex(String h) => Uint8List.fromList(<int>[
      for (int i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
    ]);

void main() {
  group('dice', () {
    test('standard and custom dice, rolls typed', () {
      expect(kStandardFaces, <int>[2, 4, 6, 8, 10, 12, 20]);
      expect(Die(20).fairBits, closeTo(4.3219, 1e-4));
      expect(Die(52).isStandard, isFalse);
      expect(() => Die(1), throwsArgumentError);
      expect(() => Die(kMaxFaces + 1), throwsArgumentError);
      expect(Die(6).parseRoll(' 4 '), 4);
      expect(Die(10).parseRoll('0'), 10, reason: 'a D10 reads 0 for 10');
      for (final String bad in <String>['0', '7', 'x', '2.5', '-1']) {
        expect(() => Die(6).parseRoll(bad), throwsFormatException, reason: bad);
      }
    });

    test('canonical JSON: sorted keys, no spaces, dice in order', () {
      final DiceRolls r = DiceRolls(<DieRolls>[
        DieRolls(Die(6), <int>[3, 1, 6]),
        DieRolls(Die(20), <int>[17, 2]),
      ]);
      expect(
        r.canonicalJson(),
        '{"dice":[{"faces":6,"rolls":[3,1,6]},{"faces":20,"rolls":[17,2]}],'
        '"format":"dragon-dice/1"}',
      );
      expect(r.rollCount, 5);
      expect(r.fairBits, closeTo(3 * math.log(6) / math.ln2 + 2 * math.log(20) / math.ln2, 1e-9));
    });

    test('any spacing or key order parses back to the same canonical JSON', () {
      const String loose = '''
        { "format": "dragon-dice/1",
          "dice": [ { "rolls": [3, 1, 6], "faces": 6 } ] }''';
      expect(DiceRolls.parse(loose).canonicalJson(),
          '{"dice":[{"faces":6,"rolls":[3,1,6]}],"format":"dragon-dice/1"}');
    });

    test('a file in any other shape is refused', () {
      for (final String bad in <String>[
        '[]',
        '{"dice":[],"format":"dragon-dice/2"}',
        '{"dice":[],"format":"dragon-dice/1","extra":1}',
        '{"dice":[{"faces":6,"rolls":[7]}],"format":"dragon-dice/1"}',
        '{"dice":[{"faces":1,"rolls":[]}],"format":"dragon-dice/1"}',
        '{"dice":[{"faces":6,"rolls":[1.5]}],"format":"dragon-dice/1"}',
        '{"dice":[{"faces":6}],"format":"dragon-dice/1"}',
        'not json',
      ]) {
        expect(() => DiceRolls.parse(bad), throwsFormatException, reason: bad);
      }
    });

    test('digest bits are read most significant first', () {
      final Uint8List d = _hex('a5ff');
      expect(digestBits(d, 8), <int>[1, 0, 1, 0, 0, 1, 0, 1]);
      expect(digestBits(d, 12), <int>[1, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 1]);
    });
  });

  group('BIP39', () {
    // The reference vectors of BIP39 (trezor/python-mnemonic vectors.json).
    test('reference vectors', () {
      final Map<String, String> vectors = <String, String>{
        '00000000000000000000000000000000':
            'abandon abandon abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon about',
        '7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f':
            'legal winner thank year wave sausage worth useful legal winner '
            'thank yellow',
        '80808080808080808080808080808080':
            'letter advice cage absurd amount doctor acoustic avoid letter '
            'advice cage above',
        'ffffffffffffffffffffffffffffffff':
            'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong',
        '0000000000000000000000000000000000000000000000000000000000000000':
            '${List<String>.filled(23, 'abandon').join(' ')} art',
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff':
            '${List<String>.filled(23, 'zoo').join(' ')} vote',
      };
      vectors.forEach((String entropy, String words) {
        expect(bip39Mnemonic(_hex(entropy)), words, reason: entropy);
      });
    });

    test('word counts and the digest prefix', () {
      expect(<int>[for (final int b in kBip39EntropyBits) bip39Words(b)],
          <int>[12, 15, 18, 21, 24]);
      final Uint8List digest = Uint8List(64)..fillRange(0, 64, 0xff);
      expect(bip39FromDigest(digest, entropyBits: 128),
          'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong');
      expect(() => bip39FromDigest(digest, entropyBits: 100), throwsArgumentError);
    });
  });

  group('estimator', () {
    test('a coin under the flat prior: P(min-entropy < h) = 2(1 − 2^−h)', () {
      // p ~ Beta(1, 1) is uniform; min-entropy < h iff max(p, 1 − p) > 2^−h.
      final EntropyDistribution d = perRollPrior(Die(2));
      for (final double h in <double>[0.25, 0.5, 0.75]) {
        expect(d.probabilityBelow(h), closeTo(2 * (1 - math.pow(2, -h)), 0.01),
            reason: 'h = $h');
      }
    });

    test('more fair-looking rolls: the curve moves up, the tail below shrinks',
        () {
      DiceRolls rolls(int perFace) => DiceRolls(<DieRolls>[
            DieRolls(Die(6),
                <int>[for (int i = 0; i < perFace; i++) ...<int>[1, 2, 3, 4, 5, 6]]),
          ]);
      final EntropyDistribution few = totalEntropy(rolls(2));
      final EntropyDistribution many = totalEntropy(rolls(20));
      final double fair = math.log(6) / math.ln2;
      expect(many.median, greaterThan(few.median));
      expect(many.median, lessThan(20 * 6 * fair), reason: 'never above fair');
      expect(many.median / (20 * 6 * fair), greaterThan(0.85));
      final double target = 0.5 * 20 * 6 * fair;
      expect(many.probabilityBelow(target), lessThan(0.01));
    });

    test('Shannon is never below min-entropy; Jeffreys is the most cautious',
        () {
      final DiceRolls r = DiceRolls(<DieRolls>[
        DieRolls(Die(20), <int>[for (int i = 1; i <= 20; i++) i]),
      ]);
      final EntropyDistribution min = totalEntropy(r);
      final EntropyDistribution shannon =
          totalEntropy(r, const EstimatorSettings(measure: EntropyMeasure.shannon));
      expect(shannon.median, greaterThan(min.median));
      final EntropyDistribution jeffreys =
          totalEntropy(r, const EstimatorSettings(prior: Prior.jeffreys));
      final EntropyDistribution nearFair =
          totalEntropy(r, const EstimatorSettings(prior: Prior.nearFair));
      expect(jeffreys.median, lessThan(min.median));
      expect(nearFair.median, greaterThan(min.median));
    });

    test('the same rolls draw the same curve; dice add up', () {
      final DiceRolls a = DiceRolls(<DieRolls>[DieRolls(Die(6), <int>[1, 2, 3])]);
      expect(totalEntropy(a).samples, totalEntropy(a).samples);
      final DiceRolls two = DiceRolls(<DieRolls>[
        DieRolls(Die(6), <int>[1, 2, 3]),
        DieRolls(Die(6), <int>[4, 5, 6]),
      ]);
      expect(totalEntropy(two).median,
          closeTo(2 * totalEntropy(a).median, 0.15 * totalEntropy(a).median));
      expect(totalEntropy(DiceRolls()).median, 0);
    });

    test('quantiles and histogram', () {
      final EntropyDistribution d = EntropyDistribution(<double>[3, 1, 2, 4]);
      expect(d.quantile(0), 1);
      expect(d.quantile(1), 4);
      expect(d.median, 2.5);
      expect(d.probabilityBelow(2.5), 0.5);
      expect(d.histogram(0, 4, 4), <int>[0, 1, 1, 2]);
    });
  });

  test('the text curve marks the target on its axis', () {
    final EntropyDistribution d =
        EntropyDistribution(<double>[for (int i = 0; i < 100; i++) 30 + i / 10]);
    final List<String> lines = textCurve(d, 32, width: 40).split('\n');
    expect(lines, hasLength(3));
    expect(lines[0].length, 40);
    expect(lines[1].length, 40);
    expect('┼'.allMatches(lines[1]), hasLength(1));
    expect(lines[2], startsWith('0'));
    expect(lines[2], contains('32'));
  });

  group('frozen vectors', () {
    test('format dragon-dice/1', () async {
      final Object? file = jsonDecode(
          await File('test_vectors/dragon-dice-1.json').readAsString());
      final List<Object?> cases = (file! as Map<String, Object?>)['cases']! as List<Object?>;
      expect(cases, isNotEmpty);
      for (final Object? c in cases) {
        final Map<String, Object?> v = c! as Map<String, Object?>;
        final DiceRolls r = DiceRolls.parse(v['json']! as String);
        final Uint8List digest = r.digest();
        expect(r.canonicalJson(), v['json']);
        expect(_toHex(digest), v['sha512']);
        expect(bip39FromDigest(digest, entropyBits: 128), v['bip39_128']);
        expect(bip39FromDigest(digest, entropyBits: 256), v['bip39_256']);
      }
    });
  });
}

String _toHex(List<int> b) =>
    b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();
