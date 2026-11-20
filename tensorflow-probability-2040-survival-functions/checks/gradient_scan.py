"""Values and gradients at boundary, out-of-support and tail points.

Usage:
  python gradient_scan.py scan LABEL OUT.json
  python gradient_scan.py compare BEFORE.json AFTER.json

`scan` records, at each point, survival_function, log_survival_function and
the gradient of each with respect to every parameter and to x.  `compare`
lists every quantity that was finite before and is NaN or infinite after
(a regression), and counts the opposite direction.
"""
import json
import math
import os
import sys

os.environ.setdefault('TF_CPP_MIN_LOG_LEVEL', '3')


def scan(label, out):
  import numpy as np  # pylint: disable=g-import-not-at-top
  import tensorflow as tf
  from tensorflow_probability.python.distributions import beta
  from tensorflow_probability.python.distributions import binomial
  from tensorflow_probability.python.distributions import chi2
  from tensorflow_probability.python.distributions import exponential
  from tensorflow_probability.python.distributions import gamma
  specs = {
      'Chi2': (lambda p: chi2.Chi2(p[0]), ['df'],
               [[0.5], [1.], [2.], [5.]], [0., 1e-300, 0.5, 3., 50.]),
      'Gamma': (lambda p: gamma.Gamma(p[0], p[1]), ['concentration', 'rate'],
                [[0.5, 2.], [1., 1.], [3., 0.5]],
                [-2., 0., 1e-300, 0.7, 30.]),
      'Gamma(log_rate)': (lambda p: gamma.Gamma(p[0], log_rate=p[1]),
                          ['concentration', 'log_rate'],
                          [[0.5, 0.3], [1., 0.], [3., -1.]],
                          [-2., 0., 0.7, 30.]),
      'Beta': (lambda p: beta.Beta(p[0], p[1]),
               ['concentration1', 'concentration0'],
               [[0.5, 0.5], [1., 1.], [2., 3.], [50., 200.]],
               [-0.5, 0., 1e-300, 0.3, 0.5, 0.999999, 1., 1.5]),
      'Binomial': (lambda p: binomial.Binomial(p[0], probs=p[1]),
                   ['total_count', 'probs'],
                   [[10., 0.3], [1., 0.5], [50., 0.01]],
                   [-1., 0., 1., 9., 10., 49., 50., 60.]),
      'Binomial(logits)': (lambda p: binomial.Binomial(p[0], logits=p[1]),
                           ['total_count', 'logits'],
                           [[10., -0.8], [50., -4.6]],
                           [-1., 0., 9., 10., 49., 50.]),
      'Exponential': (lambda p: exponential.Exponential(p[0]), ['rate'],
                      [[0.5], [2.]], [-1., 0., 1e-300, 3., 600.]),
  }
  points = {}
  for name, (make, pnames, plist, xs) in specs.items():
    for ps in plist:
      for x in xs:
        pt = [tf.constant(np.float64(v)) for v in ps]
        xt = tf.constant(np.float64(x))
        with tf.GradientTape(persistent=True) as tape:
          tape.watch(pt + [xt])
          d = make(pt)
          sf = d.survival_function(xt)
          lsf = d.log_survival_function(xt)
        gs = tape.gradient(sf, pt + [xt])
        gl = tape.gradient(lsf, pt + [xt])
        q = {'survival_function': float(sf),
             'log_survival_function': float(lsf)}
        for pn, g in zip(pnames + ['x'], gs):
          q[f'd survival_function / d {pn}'] = 0. if g is None else float(g)
        for pn, g in zip(pnames + ['x'], gl):
          q[f'd log_survival_function / d {pn}'] = (
              0. if g is None else float(g))
        points[f'{name}{ps} at x={x}'] = q
  with open(out, 'w') as f:
    json.dump(dict(label=label, points=points), f, indent=1)
  n_bad = sum(not math.isfinite(v) for q in points.values() for v in q.values())
  print(f'[{label}] {len(points)} points, {n_bad} non-finite quantities')


def compare(before_path, after_path):
  before = json.load(open(before_path))['points']
  after = json.load(open(after_path))['points']
  regressions, fixed = [], 0
  for point, qb in before.items():
    for qname, vb in qb.items():
      va = after[point][qname]
      if math.isfinite(vb) and not math.isfinite(va):
        regressions.append((point, qname, vb, va))
      elif not math.isfinite(vb) and math.isfinite(va):
        fixed += 1
  print(f'points: {len(before)}')
  print(f'non-finite before, finite after: {fixed}')
  print(f'finite before, non-finite after: {len(regressions)}')
  for point, qname, vb, va in regressions:
    print(f'  {point}: {qname}: {vb!r} -> {va!r}')


if __name__ == '__main__':
  if sys.argv[1] == 'scan':
    scan(sys.argv[2], sys.argv[3])
  else:
    compare(sys.argv[2], sys.argv[3])
