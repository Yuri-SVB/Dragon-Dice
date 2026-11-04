/// Dragon Dice: entropy from real dice that anyone can audit.
///
/// Rolls of one or more physical dice (D2 to D20, or a custom die) become a
/// canonical JSON whose SHA-512 is the secret ([DiceRolls]). A Bayesian
/// estimate says how much entropy the rolls carry if the dice may be biased
/// ([totalEntropy]). The digest feeds a BIP39 mnemonic ([bip39FromDigest]) or
/// any other use that needs bits ([digestBits]).
library;

export 'src/bip39.dart' show bip39FromDigest, bip39Mnemonic, bip39Words, kBip39EntropyBits;
export 'src/dice.dart';
export 'src/estimator.dart';
export 'src/prng.dart';
export 'src/sources.dart';
export 'src/text_curve.dart';
