"""Survival functions and their gradients under XLA, against eager mode.

Usage: python xla_check.py

For each distribution, evaluates survival_function, log_survival_function and
the gradient of survival_function with respect to the first parameter, once
eagerly and once inside tf.function(jit_compile=True), and checks that
  * XLA and eager agree to 1e-12 relative (NaN counts as equal to NaN),
  * the XLA values match scipy to 1e-10 relative,
  * the XLA gradients are finite.
Exits non-zero if any check fails.
"""
import os
import sys

os.environ.setdefault('TF_CPP_MIN_LOG_LEVEL', '3')

import numpy as np  # pylint: disable=g-import-not-at-top
from scipy import stats
import tensorflow as tf
from tensorflow_probability.python.distributions import beta
from tensorflow_probability.python.distributions import binomial
from tensorflow_probability.python.distributions import chi2
from tensorflow_probability.python.distributions import exponential
from tensorflow_probability.python.distributions import gamma

f64 = np.float64
CASES = [
    ('Chi2', lambda p: chi2.Chi2(p), f64([1.80006, 20., 3.]),
     f64([90.5982, 100., 1300.]), lambda p, x: stats.chi2.sf(x, p)),
    ('Gamma', lambda p: gamma.Gamma(p, f64(3.)), f64([2., 0.5, 5.]),
     f64([20., -1., 15.]), lambda p, x: stats.gamma.sf(x, p, scale=1 / 3.)),
    ('Beta', lambda p: beta.Beta(p, f64(200.)), f64([50., 2., 3.]),
     f64([0.5, 0.97, 1.5]), lambda p, x: stats.beta.sf(x, p, 200.)),
    ('Binomial', lambda p: binomial.Binomial(f64(50.), probs=p),
     f64([0.01, 0.3, 0.5]), f64([25., 49., -1.]),
     lambda p, x: stats.binom.sf(x, 50, p)),
    ('Exponential', lambda p: exponential.Exponential(p), f64([2., 0.5, 1.]),
     f64([20., 600., -1.]), lambda p, x: stats.expon.sf(x, scale=1 / p)),
]


def main():
  ok = True
  for name, make, p, x, ref in CASES:
    def f(p, x, make=make):
      with tf.GradientTape() as tape:
        tape.watch(p)
        d = make(p)
        sf = d.survival_function(x)
        lsf = d.log_survival_function(x)
      return sf, lsf, tape.gradient(sf, p)
    eager = f(tf.constant(p), tf.constant(x))
    xla = tf.function(f, jit_compile=True)(tf.constant(p), tf.constant(x))
    same = all(np.allclose(a.numpy(), b.numpy(), rtol=1e-12, atol=0,
                           equal_nan=True) for a, b in zip(eager, xla))
    accurate = np.allclose(xla[0].numpy(), ref(p, x), rtol=1e-10, atol=0)
    finite = bool(np.all(np.isfinite(xla[2].numpy())))
    ok &= same and accurate and finite
    print(f'{name:12s} XLA == eager: {same}   XLA vs scipy: {accurate}   '
          f'finite gradients: {finite}')
  print('ALL OK' if ok else 'FAILED')
  sys.exit(0 if ok else 1)


if __name__ == '__main__':
  main()
