"""Survival-function values for the cases in the PR, against mpmath.

Usage: python reference_cases.py LABEL OUT.json

Evaluates each case with the TensorFlow Probability on the Python path
(unmodified or fixed) and with mpmath at 100 digits, and prints one row per
case.  Reference formulas are chosen so mpmath never subtracts two nearly
equal numbers: upper tails use the complementary function directly.
"""
import json
import os
import sys

os.environ.setdefault('TF_CPP_MIN_LOG_LEVEL', '3')

import mpmath as mp  # pylint: disable=g-import-not-at-top
import numpy as np
from tensorflow_probability.python.distributions import beta
from tensorflow_probability.python.distributions import binomial
from tensorflow_probability.python.distributions import chi2
from tensorflow_probability.python.distributions import exponential
from tensorflow_probability.python.distributions import gamma

mp.mp.dps = 100
f64 = np.float64


def upper_gamma(a, z):
  return mp.gammainc(mp.mpf(a), mp.mpf(z), mp.inf, regularized=True)


def beta_sf_upper(a, b, x):  # I_{1-x}(b, a), exact for x given as a float
  return mp.betainc(mp.mpf(b), mp.mpf(a), 0, 1 - mp.mpf(x), regularized=True)


def beta_sf_lower(a, b, x):  # 1 - I_x(a, b), for results not near 0
  return 1 - mp.betainc(mp.mpf(a), mp.mpf(b), 0, mp.mpf(x), regularized=True)


def binom_sf(n, p, k):  # P[X > k] = I_p(k + 1, n - k)
  return mp.betainc(k + 1, n - k, 0, mp.mpf(p), regularized=True)


CASES = [
    ('Chi2(1.80006).survival_function(90.5982)',
     lambda: chi2.Chi2(f64(1.80006)), 90.5982,
     lambda: upper_gamma(mp.mpf(1.80006) / 2, mp.mpf(90.5982) / 2)),
    ('Chi2(20).survival_function(100)',
     lambda: chi2.Chi2(f64(20.)), 100.,
     lambda: upper_gamma(10, 50)),
    ('Chi2(3).survival_function(1300)',
     lambda: chi2.Chi2(f64(3.)), 1300.,
     lambda: upper_gamma(mp.mpf(3) / 2, 650)),
    ('Gamma(2, 3).survival_function(20)',
     lambda: gamma.Gamma(f64(2.), f64(3.)), 20.,
     lambda: upper_gamma(2, 60)),
    ('Beta(50, 200).survival_function(0.5)',
     lambda: beta.Beta(f64(50.), f64(200.)), 0.5,
     lambda: beta_sf_upper(50, 200, 0.5)),
    ('Beta(2, 3).survival_function(0.999999)',
     lambda: beta.Beta(f64(2.), f64(3.)), 0.999999,
     lambda: beta_sf_upper(2, 3, 0.999999)),
    ('Beta(0.01, 1).survival_function(1e-20)',
     lambda: beta.Beta(f64(0.01), f64(1.)), 1e-20,
     lambda: beta_sf_lower(0.01, 1, 1e-20)),
    ('Beta(1e-4, 1).survival_function(1e-300)',
     lambda: beta.Beta(f64(1e-4), f64(1.)), 1e-300,
     lambda: beta_sf_lower(1e-4, 1, 1e-300)),
    ('Binomial(50, probs=0.01).survival_function(25)',
     lambda: binomial.Binomial(f64(50.), probs=f64(0.01)), 25.,
     lambda: binom_sf(50, 0.01, 25)),
    ('Binomial(1000, probs=0.3).survival_function(600)',
     lambda: binomial.Binomial(f64(1000.), probs=f64(0.3)), 600.,
     lambda: binom_sf(1000, 0.3, 600)),
    ('Exponential(2).survival_function(20)',
     lambda: exponential.Exponential(f64(2.)), 20.,
     lambda: mp.exp(-40)),
]


def main():
  label, out = sys.argv[1], sys.argv[2]
  rows = []
  print(f'{"call":52s} {"value":>14s} {"reference":>14s} {"rel. error":>10s}'
        f'  {"log value":>12s} {"log reference":>13s}')
  for name, make, x, ref in CASES:
    dist = make()
    sf = float(dist.survival_function(f64(x)))
    lsf = float(dist.log_survival_function(f64(x)))
    r = ref()
    rel = float(abs(mp.mpf(sf) - r) / r)
    print(f'{name:52s} {sf:14.6e} {float(r):14.6e} {rel:10.1e}'
          f'  {lsf:12.4f} {float(mp.log(r)):13.4f}')
    rows.append(dict(call=name, value=sf, reference=float(r), rel_error=rel,
                     log_value=lsf, log_reference=float(mp.log(r))))
  worst = max(r['rel_error'] for r in rows)
  print(f'[{label}] worst relative error: {worst:.1e}')
  with open(out, 'w') as f:
    json.dump(dict(label=label, worst_rel_error=worst, cases=rows), f, indent=1)


if __name__ == '__main__':
  main()
