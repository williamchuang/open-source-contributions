# TensorFlow Probability: survival functions without `1 − cdf`

**Status:** [PR #2043](https://github.com/tensorflow/probability/pull/2043) opened 2026-11-18, awaiting review.
**Issue:** [tensorflow/probability#2040](https://github.com/tensorflow/probability/issues/2040).
**Fix, tests and verification:** William Chuang (Logarchéon Inc.), with Claude (Anthropic) as coding assistant.

## The bug

TensorFlow Probability (TFP) is Google's library of probability distributions
for TensorFlow, JAX and NumPy. The survival function of a distribution is the
upper-tail probability `P[X > x]`, used for p-values, tail risk and
reliability. `Chi2`, `Gamma`, `Beta` and `Binomial` did not implement it, so
TFP fell back to `1 − cdf(x)`, and `log_survival_function` to `log1p(−cdf(x))`.

When the true value is below about 1e-16, `cdf(x)` rounds to 1 and the
subtraction loses every digit:

| Call | Unmodified `main` | True value |
|---|---|---|
| `Chi2(1.80006).survival_function(90.5982)` | `0.0` | `1.353747e-20` |
| `Gamma(2, 3).survival_function(20)` | `0.0` | `5.341472e-25` |
| `Beta(50, 200).survival_function(0.5)` | `1.110223e-16` | `3.930292e-23` |
| `Binomial(1000, probs=0.3).survival_function(600)` | `1.110223e-16` | `4.054686e-86` |
| `Exponential(2).survival_function(20)` | `0.0` | `4.248354e-18` |

The loss starts well before 1e-16: `Chi2(20).survival_function(100)`, whose
value is about 1.3e-12, comes out with a relative error of 4e-5. The log
survival function becomes `−inf` or sticks at `−36.7368` (the log of
1.1e-16) whatever the true value.

## The fix

[`fix.patch`](fix.patch) (9 files, +203), identical to the commit in PR #2043:

| Distribution | `survival_function(x)` after the fix |
|---|---|
| `Chi2` | `igammac(df / 2, x / 2)` |
| `Gamma` | `igammac(concentration, rate · x)`; 1 for `x ≤ 0` |
| `Beta` | `betainc(c0, c1, 1 − x)` or `1 − betainc(c1, c0, x)`, chosen per point; 1 for `x ≤ 0`, 0 for `x ≥ 1` |
| `Binomial` | `betainc(k + 1, n − k, p)` (new helper `_bdtrc`); 1 for `k < 0`, 0 for `k ≥ n` |

- `igammac` and `betainc` with these arguments compute the upper tail
  directly, so no subtraction from 1 takes place.
- Each `_log_survival_function` is `log(survival_function)`, as TFP's `Poisson`
  already does.
- Outside the support, each branch is evaluated at a safe interior point and
  the result selected afterwards (TFP's double-`where` pattern), so gradients
  stay finite there.
- `Exponential` subclasses `Gamma`, so it inherits the new function:
  `igammac(1, rate · x) = exp(−rate · x)`.
- Regression tests are added to the five test files of these distributions.

**Why Beta needs two formulas.** The identity `1 − I_x(a, b) = I_{1−x}(b, a)`
removes the subtraction, but computing `1 − x` rounds away `x` when `x` is
tiny. On its own it would turn `Beta(0.01, 1).survival_function(1e-20)` from
the correct 0.369 into 1.0. The absolute errors of the two forms are about

| Form | Absolute error |
|---|---|
| direct, `1 − I_x(a, b)` | `ε · cdf(x)` |
| complement, `I_{1−x}(b, a)` | `ε · ((1 − x) · pdf(x) + sf(x))` |

where `ε` is the machine epsilon, and the code evaluates the form with the
smaller bound at each point.

## Verification

Run `./reproduce.sh` (needs `git` and `python3`; tested with Python 3.13 on
Linux x86_64, CPU only). It creates a virtual environment with pinned versions
(TensorFlow 2.21.0, SciPy 1.18.1, mpmath 1.4.1), checks out TFP `main` at
`df8c454`, and runs every check on the unmodified code and with the fix.
`EXTENDED=1 ./reproduce.sh` adds TFP's randomized property tests and the NumPy and
JAX substrates. On the machine used here, after package installation, the
quick run took about 10 minutes and `EXTENDED=1` about 15 more. Outputs are written
to [`results/`](results/).

| Check | Unmodified `main` | With the fix |
|---|---|---|
| New regression tests | 6 fail (5 upper tail, 1 gradient) | all pass |
| Five changed test files (505 tests) | — | **505/505** |
| Same files on the NumPy and JAX substrates (170 tests each) | — | **all pass** |
| TFP property and platform tests, affected classes (137 cases) | — | **128 pass, 9 skipped, 0 fail** |
| 11 reference cases: worst relative error | 2.7e+69 | **4.6e-13** |
| Random sweep, float64, 1,406 points: off by more than 1% | 415 | **0** |
| Random sweep, float64: largest relative error | 4.6e+286 | **3.9e-12** |
| Random sweep, float32, 747 points: off by more than 1% | 181 | **0** |
| Gradient scan, 940 quantities: NaN or infinite | 146 | **34** (see below) |
| XLA (`jit_compile=True`) vs eager, values and gradients, five classes | — | **agree to 1e-12** |

### Reference values

[`checks/reference_cases.py`](checks/reference_cases.py) evaluates 11 cases with
TFP and with mpmath at 100 digits. The reference formulas compute the upper
tail directly, so mpmath itself never subtracts two nearly equal numbers. The
two Beta cases near 0 test the second formula: both versions get them right,
and the fix keeps them right.

### Random sweeps

[`checks/sweep.py`](checks/sweep.py) draws parameters and points with a fixed
seed, from the bulk of each distribution out to the far tail, including
`Gamma(log_rate=…)` and `Binomial(logits=…)`. Inputs are rounded to the working
type first, and mpmath is evaluated at exactly those rounded inputs, so the
comparison measures only TFP's error. Points whose true value is below the
smallest normal number of the type are skipped, since no implementation can
return them. Per-distribution figures are in `results/*-sweep-*.log`.

### Gradients

[`checks/gradient_scan.py`](checks/gradient_scan.py) records the value, the log
value and every gradient (with respect to each parameter and `x`) at 125
boundary, out-of-support and tail points. 116 quantities that were NaN or
infinite become finite. Of the 34 that remain non-finite with the fix:

- 24 are `log_survival_function = −inf` where the survival value is exactly 0
  (Beta at `x ≥ 1`, Binomial at `k ≥ n`). These are the correct values.
- 6 are the derivative of `Chi2` with respect to `x` at `x = 0`, unchanged by
  the fix: `−inf` for `df < 2`, where the density is infinite at 0, and NaN
  for `df = 2`, as before.
- 4 are at `Beta(50, 200)` with `x = 0.999999`, whose true survival value is
  about 1e-1200, below the range of float64. `log_survival_function` becomes
  `−inf` and its three gradients NaN. The unmodified code returned −36.7 with
  zero gradients there, which was also wrong.

[`results/gradient-comparison.log`](results/gradient-comparison.log) lists
every quantity that was finite before and is not after; those 4 are the only
ones.

### NumPy and JAX

TFP generates its NumPy and JAX backends from the TensorFlow source with
`substrates/meta/rewrite.py`; a complete build needs Bazel.
[`checks/substrates.sh`](checks/substrates.sh) instead installs the released
TFP 0.25.0, which ships both backends, and overwrites the changed modules and
tests in a copy with versions rewritten from the fixed source. As a check on
this method, the unmodified modules at `df8c454` are rewritten too and compared
with the released files: they agree except for one comment line
(`# Dependency imports`) in four of the five modules
([`results/substrate-faithfulness.log`](results/substrate-faithfulness.log)).

### Not covered

- No run on GPU or TPU.
- `log(survival_function)` still returns `−inf` once the survival value falls
  below the float64 range (about 1e-308), as `Poisson` and `Beta`'s log CDF
  already do. Covering that range needs asymptotic expansions.
- TFP's property tests use Hypothesis; they ran with 10 examples per test
  (`TFP_HYPOTHESIS_MAX_EXAMPLES=10`).
- The NumPy and JAX backends were tested through the overlay described above,
  not through TFP's Bazel build.

## Files

```
fix.patch                    the change submitted as PR #2043
reproduce.sh                 sets up the environment, runs every check, writes results/
checks/reference_cases.py    11 cases against mpmath at 100 digits
checks/sweep.py              seeded random sweep, float64 and float32
checks/gradient_scan.py      values and gradients at 125 points; compare mode
checks/xla_check.py          XLA against eager mode and scipy
checks/property_test_ids.txt the 137 property and platform test cases run
checks/substrates.sh         NumPy and JAX substrates through the 0.25.0 overlay
results/                     logs and JSON from the run recorded here
```
