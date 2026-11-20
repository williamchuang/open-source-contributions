"""Random sweep of survival functions against mpmath, bulk to far tail.

Usage: python sweep.py LABEL {float64,float32} OUT.json

Draws parameters and points with a fixed seed, rounds them to the working
dtype, and compares `survival_function` with mpmath evaluated at those exact
rounded inputs.  Points whose true value is below the dtype's smallest
normal number are skipped, since no implementation can return them.
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
from tensorflow_probability.python.distributions import gamma

mp.mp.dps = 50


def main():
  label, dtype_name, out = sys.argv[1], sys.argv[2], sys.argv[3]
  dt = np.dtype(dtype_name).type
  tiny = float(np.finfo(dt).tiny)
  n_points = 300 if dt is np.float64 else 200
  rng = np.random.default_rng(2040)
  errs = {}

  def add(name, value, ref):
    ref = float(ref)
    if ref >= tiny:
      errs.setdefault(name, []).append(abs(value - ref) / ref)

  def m(v):  # exact mpmath copy of a rounded input
    return mp.mpf(float(v))

  for _ in range(n_points):
    a = dt(10**rng.uniform(-1, 2.5))
    r = dt(10**rng.uniform(-1, 1))
    x = dt((float(a) / float(r)) * 10**rng.uniform(-0.5, 1.6))
    ref = mp.gammainc(m(a), m(r) * m(x), mp.inf, regularized=True)
    add('Gamma', float(gamma.Gamma(a, r).survival_function(x)), ref)
    add('Gamma(log_rate)', float(gamma.Gamma(
        a, log_rate=dt(np.log(r))).survival_function(x)),
        mp.gammainc(m(a), mp.exp(m(dt(np.log(r)))) * m(x), mp.inf,
                    regularized=True))
    k, xx = dt(2 * a), dt(2 * x)
    add('Chi2', float(chi2.Chi2(k).survival_function(xx)),
        mp.gammainc(m(k) / 2, m(xx) / 2, mp.inf, regularized=True))
  for _ in range(n_points):
    a = dt(10**rng.uniform(-0.5, 2.5))
    b = dt(10**rng.uniform(-0.5, 2.5))
    x = dt(rng.uniform(0.01, 0.9999999))
    ref = mp.betainc(m(b), m(a), 0, 1 - m(x), regularized=True)
    add('Beta', float(beta.Beta(a, b).survival_function(x)), ref)
  for _ in range(n_points):
    n = dt(rng.integers(1, 2000))
    p = dt(10**rng.uniform(-4, -0.01))
    k = dt(rng.integers(0, int(n)))
    ref = mp.betainc(m(k) + 1, m(n) - m(k), 0, m(p), regularized=True)
    add('Binomial', float(binomial.Binomial(
        n, probs=p).survival_function(k)), ref)
    lg = dt(np.log(p) - np.log1p(-p))
    p_from_logits = 1 / (1 + mp.exp(-m(lg)))
    add('Binomial(logits)', float(binomial.Binomial(
        n, logits=lg).survival_function(k)),
        mp.betainc(m(k) + 1, m(n) - m(k), 0, p_from_logits, regularized=True))

  summary = {}
  for name, v in errs.items():
    v = np.array(v)
    summary[name] = dict(points=int(v.size), max_rel_error=float(v.max()),
                         median_rel_error=float(np.median(v)),
                         points_off_by_more_than_1e_2=int(np.sum(v > 1e-2)))
    print(f'[{label} {dtype_name}] {name:17s} points={v.size:4d}  '
          f'median={np.median(v):.1e}  max={v.max():.1e}  '
          f'off by >1e-2: {np.sum(v > 1e-2)}')
  with open(out, 'w') as f:
    json.dump(dict(label=label, dtype=dtype_name, distributions=summary), f,
              indent=1)


if __name__ == '__main__':
  main()
