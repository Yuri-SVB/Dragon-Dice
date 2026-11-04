import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bip39_english.dart';

/// The entropy sizes BIP39 allows, in bits: 12, 15, 18, 21 or 24 words.
const List<int> kBip39EntropyBits = <int>[128, 160, 192, 224, 256];

/// Bits per BIP39 word: the wordlist has 2¹¹ words.
const int _kBitsPerWord = 11;

/// Entropy bits per checksum bit.
const int _kEntropyPerChecksumBit = 32;

/// Words in a BIP39 mnemonic of [entropyBits] bits.
int bip39Words(int entropyBits) =>
    (entropyBits + entropyBits ~/ _kEntropyPerChecksumBit) ~/ _kBitsPerWord;

/// The BIP39 English mnemonic of [entropy] (16, 20, 24, 28 or 32 bytes):
/// the entropy followed by the first `bits/32` bits of its SHA-256, read 11
/// bits a word.
String bip39Mnemonic(Uint8List entropy) {
  final int bits = entropy.length * 8;
  if (!kBip39EntropyBits.contains(bits)) {
    throw ArgumentError.value(bits, 'entropy bits', 'must be one of $kBip39EntropyBits');
  }
  final List<int> checksum = sha256.convert(entropy).bytes;
  final int total = bits + bits ~/ _kEntropyPerChecksumBit;
  int bit(int i) {
    final List<int> src = i < bits ? entropy : checksum;
    final int j = i < bits ? i : i - bits;
    return (src[j >> 3] >> (7 - (j & 7))) & 1;
  }

  final List<String> words = <String>[];
  for (int w = 0; w < total ~/ _kBitsPerWord; w++) {
    int index = 0;
    for (int b = 0; b < _kBitsPerWord; b++) {
      index = (index << 1) | bit(w * _kBitsPerWord + b);
    }
    words.add(kBip39English[index]);
  }
  return words.join(' ');
}

/// The BIP39 mnemonic of the first [entropyBits] bits of [digest] (a
/// Dragon Dice SHA-512 digest). The words carry no more entropy than the
/// rolls behind the digest.
String bip39FromDigest(Uint8List digest, {int entropyBits = 256}) {
  if (!kBip39EntropyBits.contains(entropyBits)) {
    throw ArgumentError.value(entropyBits, 'entropyBits');
  }
  final Uint8List entropy =
      Uint8List.fromList(digest.sublist(0, entropyBits ~/ 8));
  try {
    return bip39Mnemonic(entropy);
  } finally {
    entropy.fillRange(0, entropy.length, 0);
  }
}
