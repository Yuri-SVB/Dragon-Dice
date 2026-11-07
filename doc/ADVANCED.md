# Advanced mode

The vanilla flow assumes your dice are fair: a D20 roll carries
`log₂ 20 ≈ 4.32` bits, so 8 rolls carry 32 bits. Real dice are never quite
fair. Advanced mode asks instead: **given the rolls, how likely is it that
the dice are biased enough to carry less than the target?** — and shows the
answer as a curve.

## A private screen first

The curve is drawn from the rolls, so its shape gives some of them away: how
often each face came up. Eight D20 rolls that are all different, for
instance, carry 34.6 bits; knowing only that they are all different leaves
32.2. Advanced mode therefore turns on only after you confirm that no one,
and no camera, can see the screen (a dialog in the apps, `YES` in the
terminal). Vanilla mode shows only counts and is safe to use in view.

## What you see

- **The curve**: how much entropy the rolls carry, as a distribution. Its
  peak is the likeliest amount; its width, how unsure the estimate is.
- **The target**: a mark on the axis (32 bits for a Great Wall map point;
  128–256 for BIP39).
- **The median**: half the curve lies above it.
- **The chance below target**: the share of the curve left of the target.
  Rolls are ready when it is at most your **bound**.
- **Sources** (mouse, accelerometer, camera): their credit moves the whole
  curve right. See [Sources](#sources).

As you roll, the curve moves right and its relative width shrinks. A thin
curve with its median clearly past the target, and a chance below target
under your bound, is the sign to stop. How far past is your call: tighter
bounds and more cautious priors ask for more rolls.

## The fields

### Prior

What you believe about a die before rolling it. Formally a symmetric
Dirichlet distribution over the die's face probabilities `p = (p₁ … p_k)`,
with density proportional to `p₁^(α−1) ⋯ p_k^(α−1)`. One number, **α**
(alpha), sets two things:

- **Shape.** Below 1, the density rises towards the edges of the possible
  biases: badly biased dice are thought likely. At 1 it is flat: every bias
  equally likely. Above 1 it rises towards the fair die.
- **Weight.** After `n` rolls with counts `c₁ … c_k`, the belief is again a
  Dirichlet, with `α + cᵢ` for face `i` (the **posterior**). So α weighs
  against the counts: with α = 10, a D6's rolls weigh as much as the prior
  after 60 rolls (10 per face); with α = 1, after 6.

| Preset | α | Meaning |
|---|---|---|
| Jeffreys | 0.5 | Leans towards badly biased dice. The most cautious; needs the most rolls. |
| Flat (default) | 1 | Every possible bias equally plausible before rolling. |
| Near-fair | 10 | Trusts the die unless the rolls say otherwise; needs the fewest. |
| Custom | any α > 0 | Below 1 is more cautious, above 1 more trusting. |

### Entropy measure

- **Min-entropy** (default): `−log₂` of the likeliest face's probability.
  It is what an attacker who always guesses the likeliest face faces — the
  right measure for keys.
- **Shannon entropy**: the average surprise. Never below min-entropy; it
  overstates a key's strength when the die is biased.

### Bound

The highest chance of falling short of the target you accept: 1 % by
default. 0.1 % asks for more rolls; 5 % for fewer.

### How the curve is drawn

For one die with `n` rolls, the entropy the rolls carry is `n · H(p)`, where
`H` is the measure above and `p` the die's unknown face probabilities. For
several dice, it is the sum over the dice. The chance below target is the
posterior probability

```text
P(Σ n_d · H(p_d) < target)  =  ∫ 1[Σ n_d · H(p_d) < target] · Π Dir(p_d | α + c_d) dp
```

an integral over every possible bias of every die. For a coin it has a closed
form; for a die with more faces, the region below target is cut out of the
simplex by curved surfaces, and exact computation is impractical. So the
apps estimate it by **Monte Carlo integration**:

1. Draw `p_d` for each die from its posterior. A Dirichlet draw is a set of
   independent Gamma draws, one per face with shape `α + cᵢ`, divided by
   their sum (Gamma by Marsaglia–Tsang, normals by Box–Muller).
2. Compute the total entropy `Σ n_d · H(p_d)` of that draw.
3. Repeat `N` times. The curve is the histogram of the `N` totals; the chance
   below target is the fraction of them below it.

The fraction is off by about `√(P(1 − P) / N)` (one standard error). The
apps take `N = 100 / bound` (10 000 at the default 1 %), so near the bound
the error is about a tenth of the bound: whether you are under it is
measured, not guessed. The terminal app's `--samples` overrides `N`.

The draws come from a **pseudorandom** generator, xoshiro256\*\*, seeded
through SplitMix64 from the fixed seed `0x0D1CE` — not from the system's
randomness. Three reasons:

- distrust of the system's randomness is a reason to roll dice at all; the
  estimate must not rest on it;
- the same rolls always draw the same curve, so anyone can recheck it;
- the draws model the dice; they are not secret and never enter the digest.

### Custom dice

Any fair process with a fixed number of equally likely outcomes is a die:

- **D52**: draw a card from a well-shuffled deck, note it, put it back and
  shuffle well again. (Without putting it back the draws are not
  independent and the estimate does not apply.)
- **D3**: a D6 read 1–2 → 1, 3–4 → 2, 5–6 → 3 (better: just use the D6).
- **D100**: two D10s read as tens and units, 00 as 100 — but entering them
  as two D10s is simpler and just as good.

Number the outcomes 1 to N, the same way every time.

## Sources

Besides dice, the apps can mix in captures of peripherals, each credited
with the entropy it carries:

| Source | A reading | Where |
|---|---|---|
| Mouse | position (physical pixels) and time (µs) of each move over a pad | everywhere (a finger on a touch screen) |
| Accelerometer | x, y, z (m/s², 16 fractional bits) and time (µs) | phones, tablets |
| Camera | brightness (r + g + b) of a 16 × 12 grid of pixels, per frame | where a camera is found |

Only the capture's SHA-512 enters the rolls JSON
([FORMAT.md](FORMAT.md)); the readings are wiped.

**Credit: at most 1 bit per reading.** A reading is a mouse move, an
accelerometer sample or a camera frame.

- **Readings counted:** at most one per 10 ms, by the reading's time, so a
  fast-polling device earns no more than a slow one for the same motion. The
  time is never credited: it mostly shows the device's polling.
- **One symbol per reading:** how it departs from the previous move — the
  second difference `vₖ − 2vₖ₋₁ + vₖ₋₂` of each value (x and y; x, y and z;
  each pixel of the grid), its low byte, all values together. A steady stroke
  or a still scene gives one symbol over and over, so nothing.
- **Bits per symbol:** the **most common value** test of NIST SP 800-90B
  (§6.3.1). With `p̂` the frequency of the commonest symbol among `n`:

  ```text
  p_u = min(1, p̂ + 2.576 · √(p̂(1 − p̂) / (n − 1)))      bits per symbol = −log₂ p_u
  ```

  `p_u` is the 99 % upper confidence bound of `p̂`.
- **Credit:** the symbols times that figure, **capped at 1 bit per symbol**,
  and nothing below 64 symbols. The capture dialog shows it live; you stop
  when it suffices.

Why the cap: the test assumes independent symbols, and sensors are not — a
hand moves smoothly, a camera's pixels share the light. Without a cap, a few
seconds of scribbling were credited thousands of bits. Informal estimates
put a mouse position at a bit or two (Keybase's `more-entropy`); one bit per
move, at most 100 a second, stays below them. So 40 bits take about a second
of moving the mouse, and a frame of camera noise counts like a move. The
credit is still an estimate, not a guarantee — which is why it is shown per
source, next to the dice, for you to weigh.

**Counting.** The captures' credits add to the dice: in vanilla mode to the
dice's fair entropy; in advanced mode, they move the curve right. No source
is required. Finishing below target, sources included, gets the same
emphatic warning as rolls alone.

**System randomness** is different: 1024 bytes from the system's secure
generator, mixed in as a backup and never counted. If the dice or sensors
fall short, the digest still has it; if the system's generator is
compromised, the dice and sensors still carry the target. The desktop app
leaves it off by default, so you can see each source alone; apps that use
the wizard, such as Great Wall's wallet, may turn it on by default.

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
