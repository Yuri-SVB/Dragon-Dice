# Advanced mode

The vanilla flow assumes your dice are fair: a D20 roll carries
`log₂ 20 ≈ 4.32` bits, so 8 rolls carry 32 bits. Real dice are never quite
fair. Advanced mode asks instead: **given the rolls, how likely is it that
the dice are biased enough to carry less than the target?** — and shows the
answer as a curve.

## What you see

- **The curve**: how much entropy the rolls carry, as a distribution. Its
  peak is the likeliest amount; its width, how unsure the estimate is.
- **The target**: a mark on the axis (32 bits for a Great Wall map point;
  128–256 for BIP39).
- **The median**: half the curve lies above it.
- **The chance below target**: the share of the curve left of the target.
  Rolls are ready when it is at most your **bound**.

As you roll, the curve moves right and its relative width shrinks. A thin
curve with its median clearly past the target, and a chance below target
under your bound, is the sign to stop. How far past is your call: tighter
bounds and more cautious priors ask for more rolls.

## The fields

### Prior

What you believe about a die before rolling it. Formally a symmetric
Dirichlet distribution over the die's face probabilities, with one number,
**α** (alpha), per face:

| Preset | α | Meaning |
|---|---|---|
| Jeffreys | 0.5 | Leans towards badly biased dice. The most cautious; needs the most rolls. |
| Flat (default) | 1 | Every possible bias equally plausible before rolling. |
| Near-fair | 10 | Trusts the die unless the rolls say otherwise; needs the fewest. |
| Custom | any α > 0 | Below 1 is more cautious, above 1 more trusting. |

The rolls then update the belief (the **posterior**): a face that comes up
often makes "this die favours it" more plausible.

### Entropy measure

- **Min-entropy** (default): `−log₂` of the likeliest face's probability.
  It is what an attacker who always guesses the likeliest face faces — the
  right measure for keys.
- **Shannon entropy**: the average surprise. Never below min-entropy; it
  overstates a key's strength when the die is biased.

### Bound

The highest chance of falling short of the target you accept: 1 % by
default. 0.1 % asks for more rolls; 5 % for fewer.

### Samples

How many Monte Carlo draws the curve is drawn from (20 000 by default).
More is smoother and slower. The draws use a fixed seed, so the same rolls
always draw the same curve; they are not secret and carry nothing of the
rolls.

### Custom dice

Any fair process with a fixed number of equally likely outcomes is a die:

- **D52**: draw a card from a well-shuffled deck, note it, put it back and
  shuffle well again. (Without putting it back the draws are not
  independent and the estimate does not apply.)
- **D3**: a D6 read 1–2 → 1, 3–4 → 2, 5–6 → 3 (better: just use the D6).
- **D100**: two D10s read as tens and units, 00 as 100 — but entering them
  as two D10s is simpler and just as good.

Number the outcomes 1 to N, the same way every time.

## How many rolls?

Measured with fair dice, flat prior, min-entropy and a 1 % bound:

| Target | Die | Vanilla (fair) | Advanced |
|---|---|---|---|
| 32 bits | coin (D2) | 32 | about 64 |
| 32 bits | D6 | 13 | about 28 |
| 32 bits | D20 | 8 | about 18 |
| 128 bits | D6 | 50 | about 82 |
| 128 bits | D20 | 30 | about 58 |

The overhead is the price of not trusting the dice; it shrinks, relative to
the target, as the target grows.

## What it cannot see

The model assumes **independent** rolls: each roll ignores the ones before.
It catches a biased die. It does not catch rolls you chose, a die that
"remembers", a deck not shuffled between draws, or a camera over your
shoulder. It is computed on your device from the rolls themselves; nothing is
sent anywhere.
