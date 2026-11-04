# Dragon Dice

Entropy from real dice that anyone can audit.

Roll physical dice, type the rolls, and get the SHA-512 digest of their
canonical JSON — and from it a BIP39 mnemonic, or the bits any other tool
needs. Dragon Dice also tells you how much entropy the rolls carry if your
dice may be biased: a Bayesian estimate drawn as a curve you watch move past
your target as you roll.

The name nods to Dragon Ball: gathering numbered balls summons the
wish-granting dragon.

## Quick start

Needs the Dart SDK (3.3 or later). No network is needed after `dart pub get`.

```sh
git clone <this repository> dragon-dice && cd dragon-dice
dart pub get
dart run dragon_dice            # roll, then get a 24-word BIP39 mnemonic
dart run dragon_dice --help     # every option
```

A session:

```text
die> d20                 start a D20 (each die you start is another physical die)
D20> 17 2 9 14 …         its rolls, as they come (hidden as you type)
D20> d6                  start a second die
D6>  3 1 6 …
D6>                      Enter: done
```

Rolls are ready when, **if the dice are fair**, they carry the target: 256
bits for 24 words (about 60 rolls of a D20, 100 of a D6). That is the
vanilla flow: register enough rolls and press Enter. If you press it sooner,
you are warned, emphatically, and may go on anyway.

The desktop app (`app/`) does the same in a window, with the curve drawn.
It can also mix in captures of the mouse, the accelerometer and the camera,
each credited toward the target, and the system's randomness as a backup
that is never counted ([doc/ADVANCED.md](doc/ADVANCED.md#sources)).

## What you get

- **The digest**: SHA-512 of the canonical JSON of your rolls
  ([doc/FORMAT.md](doc/FORMAT.md)). Check it with any tool:
  `printf '%s' '<json>' | sha512sum`.
- **BIP39**: the mnemonic of the digest's first 128–256 bits (`--words`).
  `dart run dragon_dice bip39` also turns a digest you already have into
  words.

The same rolls always give the same digest. Never use one set of rolls for
two things: each key gets its own rolls.

## Dice

D2 (a coin), D4, D6, D8, D10, D12, D20 — faces numbered from 1; a D10 read
0 counts as 10. Mix them freely; each physical die is its own sequence, as a
die's bias is its own.

In advanced mode, any die from 2 to 1000 faces — a D52 is a card drawn from a
well-shuffled deck. See [doc/ADVANCED.md](doc/ADVANCED.md).

## Advanced mode: the Bayesian estimate

`--advanced` replaces "assume fair dice" with a Bayesian estimate: given the
rolls themselves, how likely is it that the dice are biased enough to carry
less than the target? You roll until the curve sits clearly past the target
and the chance of falling short is under your bound (1 % by default). That
takes about twice the rolls of the vanilla flow for a 32-bit target. Its
curve shows how your rolls are spread, so it asks for a private screen
first. Every field, and how the curve is computed, is explained in
[doc/ADVANCED.md](doc/ADVANCED.md).

## Where it is used

Great Wall's wallet enters a map's 32-bit point with the Dragon Dice wizard
(`ui/`), to a 40-bit target ([doc/FORMAT.md](doc/FORMAT.md#from-the-digest)
says why). Great Wall's provisional keys and Star Clock secrets are next.

## Layout

| Path | What |
|---|---|
| `lib/` | the engine: dice, canonical JSON, digest, estimator, BIP39 |
| `bin/dragon_dice.dart` | the terminal app |
| `ui/` | Flutter: the dice wizard, its curve and the peripheral captures, for apps |
| `app/` | Flutter: the desktop app |
| `test_vectors/` | frozen vectors of the format |
| `doc/` | the format and the advanced mode |

`dart test` runs the engine's tests, the frozen vectors included.

## Licence

MIT OR Apache-2.0.
