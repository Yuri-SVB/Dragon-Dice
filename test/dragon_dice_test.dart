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
        '"version":"dragon-dice/1"}',
      );
      expect(r.rollCount, 5);
      expect(r.fairBits, closeTo(3 * math.log(6) / math.ln2 + 2 * math.log(20) / math.ln2, 1e-9));
    });

    test('any spacing or key order parses back to the same canonical JSON', () {
      const String loose = '''
        { "version": "dragon-dice/1",
          "dice": [ { "rolls": [3, 1, 6], "faces": 6 } ] }''';
      expect(DiceRolls.parse(loose).canonicalJson(),
          '{"dice":[{"faces":6,"rolls":[3,1,6]}],"version":"dragon-dice/1"}');
    });

    test('a file in any other shape is refused', () {
      for (final String bad in <String>[
        '[]',
        '{"dice":[],"version":"dragon-dice/2"}',
        '{"dice":[],"format":"dragon-dice/1"}',
        '{"dice":[],"version":"dragon-dice/1","extra":1}',
        '{"dice":[],"system":{},"version":"dragon-dice/1"}',
        '{"dice":[],"system":{"mouse":"ab"},"version":"dragon-dice/1"}',
        '{"dice":[],"system":{"radio":"${'ab' * 64}"},"version":"dragon-dice/1"}',
        '{"dice":[{"faces":6,"rolls":[7]}],"version":"dragon-dice/1"}',
        '{"dice":[{"faces":1,"rolls":[]}],"version":"dragon-dice/1"}',
        '{"dice":[{"faces":6,"rolls":[1.5]}],"version":"dragon-dice/1"}',
        '{"dice":[{"faces":6}],"version":"dragon-dice/1"}',
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

  group('sources', () {
    test('sources sit under "system", sorted, before the version', () {
      final DiceRolls r = DiceRolls(<DieRolls>[DieRolls(Die(6), <int>[1])])
        ..setSource(kSourceRandom, '0f' * kSystemRandomBytes)
        ..setSource(kSourceMouse, 'ab' * kDigestBytes);
      final String json = r.canonicalJson();
      expect(json, startsWith('{"dice":[{"faces":6,"rolls":[1]}],"system":{"mouse":"abab'));
      expect(json, contains('"},"version":"dragon-dice/1"}'));
      expect(json.indexOf('"mouse"'), lessThan(json.indexOf('"random"')));
      expect(DiceRolls.parse(json).canonicalJson(), json);
      expect(() => r.setSource(kSourceMouse, 'AB' * kDigestBytes), throwsArgumentError,
          reason: 'lowercase hex only');
      expect(() => r.setSource('radio', 'ab' * kDigestBytes), throwsArgumentError);
    });

    test('NIST most-common-value estimate', () {
      expect(mcvMinEntropy(List<int>.filled(100, 7)), 0);
      // 256 symbols, each once: p = 1/256, raised to its 99 % upper bound.
      final double p = 1 / 256;
      final double upper = p + 2.576 * math.sqrt(p * (1 - p) / 255);
      expect(mcvMinEntropy(<int>[for (int i = 0; i < 256; i++) i]),
          closeTo(-math.log(upper) / math.ln2, 1e-12));
    });

    test('a capture is credited by its changes, and hashed', () {
      final SensorCapture steady = SensorCapture(2);
      for (int i = 0; i < 200; i++) {
        steady.add(<int>[1000 + 3 * i, 50]);
      }
      expect(steady.credit().bits, 0, reason: 'a steady drift is no entropy');
      final SensorCapture noisy = SensorCapture(1);
      final math.Random rng = math.Random(1);
      for (int i = 0; i < 2000; i++) {
        noisy.add(<int>[rng.nextInt(1 << 20)]);
      }
      final SensorCredit c = noisy.credit();
      expect(c.perSymbol, kMaxBitsPerReading,
          reason: 'however varied, a reading is worth one bit at most');
      expect(c.bits, closeTo(c.symbols * kMaxBitsPerReading, 1e-9));
      final SensorCapture few = SensorCapture(1)..add(<int>[1])..add(<int>[9]);
      expect(few.credit().bits, 0, reason: 'too few symbols');
      expect(noisy.digestHex(), hasLength(2 * kDigestBytes));
      final String d = noisy.digestHex();
      noisy.wipe();
      expect(noisy.length, 0);
      expect(d, isNot(noisy.digestHex()));
    });

    test('one bit per move at most, one move per 10 ms, time not credited',
        () {
      // A busy device: a reading every millisecond, random values.
      const int readings = 2000;
      const int periodUs = 1000;
      final math.Random rng = math.Random(2);
      final SensorCapture busy = SensorCapture(3, timeChannel: 2);
      for (int i = 0; i < readings; i++) {
        busy.add(<int>[rng.nextInt(1 << 12), rng.nextInt(1 << 12), i * periodUs]);
      }
      const int counted = readings * periodUs ~/ kMinReadingIntervalUs;
      const int secondDifferenceSpan = 2;
      expect(busy.credit().symbols, counted - secondDifferenceSpan);
      expect(busy.credit().bits, counted - secondDifferenceSpan);
      // A steady acceleration, its clock jittering (every reading counted):
      // nothing.
      const int jitterUs = 999;
      const int spacedUs = kMinReadingIntervalUs + jitterUs + 1;
      final SensorCapture smooth = SensorCapture(2, timeChannel: 1);
      for (int i = 0; i < readings; i++) {
        smooth.add(<int>[i * i, i * spacedUs + rng.nextInt(jitterUs)]);
      }
      expect(smooth.credit().symbols, readings - secondDifferenceSpan);
      expect(smooth.credit().bits, 0);
    });

    test('system randomness: 1 KiB as hex', () {
      final String hex = systemRandomHex();
      expect(hex, hasLength(2 * kSystemRandomBytes));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(hex), isTrue);
    });
  });

  group('simulation', () {
    test('xoshiro256** seeded by SplitMix64, pinned', () {
      // Checked against an independent implementation; SplitMix64's first
      // output from 0 is the published e220a8397b1dcdaf.
      final Xoshiro256 g = Xoshiro256(0);
      String hex(int x) =>
          (x >>> 32).toRadixString(16).padLeft(8, '0') +
          (x & 0xffffffff).toRadixString(16).padLeft(8, '0');
      expect(<String>[for (int i = 0; i < 3; i++) hex(g.nextInt64())],
          <String>['99ec5f36cb75f2b4', 'bf6e1f784956452a', '1a5f849d4933e6e0']);
      final Xoshiro256 h = Xoshiro256(kEstimatorSeed);
      expect(hex(h.nextInt64()), 'dfc24148b36385e0');
      final double u = Xoshiro256(1).nextDouble();
      expect(u, inInclusiveRange(0, 1));
    });

    test('samples follow the bound', () {
      expect(samplesForBound(0.01), 10000);
      expect(samplesForBound(0.001), 100000);
      expect(samplesForBound(0.05), 2000);
      expect(kDefaultSamples, samplesForBound(kDefaultBound));
    });
  });

  group('frozen vectors', () {
    test('dragon-dice/1', () async {
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
