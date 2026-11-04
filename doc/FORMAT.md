# The rolls format: `dragon-dice/1`

The secret Dragon Dice produces is the **SHA-512 digest of the canonical JSON
of the rolls**. Anyone can recompute it with standard tools; nothing else
goes into it.

## The JSON

```json
{"dice":[{"faces":6,"rolls":[3,1,6]},{"faces":20,"rolls":[17,2]}],"format":"dragon-dice/1"}
```

- `format`: always `"dragon-dice/1"`.
- `dice`: one entry per **physical die**, in the order the dice were started.
  - `faces`: its number of faces, 2 to 1000.
  - `rolls`: its rolls in the order rolled, each a whole number from 1 to
    `faces`. (A D10 read 0 is entered as 10.)

No other keys. A die may have no rolls yet (`"rolls":[]`).

## Canonical form

The digest is taken of exactly one byte string for given rolls:

- keys sorted (`dice` before `format`, `faces` before `rolls`);
- no whitespace anywhere;
- numbers in plain decimal, no leading zeros, no sign, no fraction;
- encoded as UTF-8 (it is ASCII).

This is what Python's `json.dumps(obj, sort_keys=True, separators=(",", ":"))`
produces, so an independent check is one line:

```sh
printf '%s' '{"dice":[{"faces":6,"rolls":[3,1,6]}],"format":"dragon-dice/1"}' | sha512sum
```

The order of the dice and of each die's rolls matters: the same rolls typed
in another order are another secret.

## From the digest

- **BIP39**: the first 128, 160, 192, 224 or 256 bits of the digest are the
  entropy of a 12- to 24-word English mnemonic (BIP39's own checksum
  follows).
- **Bits**: an app that needs `n` bits takes the digest's first `n` bits,
  most significant first (Great Wall: 32 bits per map point).

The digest never carries more entropy than the rolls behind it.

## Vectors

`test_vectors/dragon-dice-1.json` freezes rolls, their canonical JSON, the
digest and both mnemonics. They were checked against Python's `hashlib` and
`sha512sum`. A change of format gets a new version tag and new vectors; the
old ones stay.
