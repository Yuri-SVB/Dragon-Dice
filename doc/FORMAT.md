# The rolls format: `dragon-dice/1`

The secret Dragon Dice produces is the **SHA-512 digest of the canonical JSON
of the rolls** and of any peripheral sources mixed in. Anyone can recompute it
with standard tools; nothing else goes into it.

## The JSON

```json
{"dice":[{"faces":6,"rolls":[3,1,6]},{"faces":20,"rolls":[17,2]}],"system":{"mouse":"9f…","random":"4a…"},"version":"dragon-dice/1"}
```

- `dice`: one entry per **physical die**, in the order the dice were started.
  - `faces`: its number of faces, 2 to 1000.
  - `rolls`: its rolls in the order rolled, each a whole number from 1 to
    `faces`. (A D10 read 0 is entered as 10.) A die may have no rolls yet.
- `system` (only when a source is mixed in): the peripheral sources, by name.
  - `accelerometer`, `camera`, `mouse`: the SHA-512 of the raw data captured,
    as 128 lowercase hex digits. The raw data is never kept.
  - `random`: 1024 bytes from the system's secure random generator, as 2048
    lowercase hex digits — a backup, never counted toward a target.
- `version`: always `"dragon-dice/1"`.

No other keys.

## Canonical form

The digest is taken of exactly one byte string for given rolls and sources:

- keys sorted (`dice`, `system`, `version`; within a die `faces`, `rolls`;
  within `system` its sources alphabetically) — which is why `version` comes
  last;
- no whitespace anywhere;
- numbers in plain decimal, no leading zeros, no sign, no fraction;
- hex in lowercase;
- encoded as UTF-8 (it is ASCII).

This is what Python's `json.dumps(obj, sort_keys=True, separators=(",", ":"))`
produces, so an independent check is one line:

```sh
printf '%s' '{"dice":[{"faces":6,"rolls":[3,1,6]}],"version":"dragon-dice/1"}' | sha512sum
```

The order of the dice and of each die's rolls matters: the same rolls typed
in another order are another secret.

With sources mixed in, the digest can be recomputed only with their values,
which are as secret as the rolls; a dice-only digest needs only the rolls.

## A capture's digest

A peripheral capture is a run of readings, each a few integer channels (a
mouse: position and time of each move; an accelerometer: x, y, z and time; a
camera: the brightness of a sparse grid of pixels, frame after frame). Its
digest is the SHA-512 of the readings, each value a big-endian 64-bit integer,
reading after reading. Only that digest enters the JSON.

## From the digest

- **BIP39**: the first 128, 160, 192, 224 or 256 bits of the digest are the
  entropy of a 12- to 24-word English mnemonic (BIP39's own checksum
  follows).
- **Bits**: an app that needs `n` bits takes the digest's first `n` bits,
  most significant first (Great Wall: 32 bits per map point).

The digest never carries more entropy than its inputs. Cutting it to few bits
also loses a little: when the inputs carry barely more than `n` bits, some
`n`-bit outputs are reached more often than others. For short outputs that an
attacker could tabulate (Great Wall's 32-bit points), the target therefore
asks for a margin over `n` (Great Wall: 40 bits for a 32-bit point). For 128
bits and more, the loss is a few bits and cannot be tabulated.

## Vectors

`test_vectors/dragon-dice-1.json` freezes rolls and sources, their canonical
JSON, the digest and both mnemonics. They were checked against Python's
`hashlib` and `sha512sum`. A change of format gets a new version tag and new
vectors; the old ones stay.
