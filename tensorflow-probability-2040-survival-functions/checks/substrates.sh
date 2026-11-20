#!/usr/bin/env bash
# Run the five changed test files on TFP's NumPy and JAX substrates.
#
# Usage: substrates.sh TFP_SOURCE_DIR WORK_DIR RESULTS_DIR
#
# TFP generates its NumPy and JAX backends from the TensorFlow source with
# substrates/meta/rewrite.py; a complete build needs Bazel.  Instead this
# installs the released tensorflow-probability 0.25.0 (which ships both
# substrates), copies it, and overwrites the changed modules and tests in the
# copy with versions rewritten from TFP_SOURCE_DIR.  As a check that the copy
# stays faithful, the unmodified modules at the base commit are rewritten too
# and compared with the released files.
set -euo pipefail
unset PYTHONPATH   # must find the installed 0.25.0 package, not the source tree
SRC="$1"; WORK="$2"; RES="$3"
PY="${PYTHON:-python3}"
D=tensorflow_probability/python/distributions
MODULES="chi2 gamma beta binomial exponential"
TESTS="chi2_test gamma_test beta_test binomial_test exponential_test"

if [ ! -x "$WORK/venv-jax/bin/python" ]; then
  "$PY" -m venv "$WORK/venv-jax"
  "$WORK/venv-jax/bin/pip" install -q tensorflow-probability==0.25.0 \
    "jax[cpu]==0.4.38" numpy==2.5.5 scipy==1.18.1 mpmath==1.4.1 \
    absl-py==2.5.1 hypothesis==6.170.15 dm-tree==0.1.10 decorator==5.3.1 \
    cloudpickle==3.1.3 gast==0.7.0 tensorflow==2.21.0 tf-keras==2.21.0
fi
JPY="$WORK/venv-jax/bin/python"
SITE="$("$JPY" -c 'import os, tensorflow_probability as t; print(os.path.dirname(t.__file__))')"
OVL="$WORK/overlay"
rm -rf "$OVL"; mkdir -p "$OVL"; cp -R "$SITE" "$OVL/"
for s in numpy jax; do
  for m in $MODULES; do
    f="$OVL/tensorflow_probability/substrates/$s/distributions/$m.py"
    [ -f "$f" ] || { echo "missing $f: not the released package?"; exit 1; }
  done
done

rewrite() {  # $1 = file, $2 = numpy|jax
  local flag=""; [ "$2" = jax ] && flag=--numpy_to_jax
  "$JPY" -I "$SRC/tensorflow_probability/substrates/meta/rewrite.py" "$1" $flag
}

{
  echo "Rewritten base-commit modules vs released 0.25.0 (differing lines shown):"
  mkdir -p "$WORK/basetree/$D"
  for m in $MODULES; do
    git -C "$SRC" show "HEAD:$D/$m.py" > "$WORK/basetree/$D/$m.py"
    for s in numpy jax; do
      rewrite "$WORK/basetree/$D/$m.py" $s > "$WORK/rewritten_${s}_${m}.py"
      d=$(diff "$WORK/rewritten_${s}_${m}.py" \
               "$OVL/tensorflow_probability/substrates/$s/distributions/$m.py" \
          | grep '^[<>]' || true)
      echo "  $s/$m.py: $(printf '%s' "$d" | grep -c . || true) line(s) ${d:+-> $d}"
    done
  done
} > "$RES/substrate-faithfulness.log"

for s in numpy jax; do
  for f in $MODULES $TESTS internal/statistical_testing; do
    rewrite "$SRC/$D/$f.py" $s > "$OVL/tensorflow_probability/substrates/$s/distributions/$f.py"
  done
done

: > "$RES/substrate-tests.log"
for s in numpy jax; do
  for t in $TESTS; do
    out=$(cd "$OVL" && PYTHONPATH="$OVL" TF_CPP_MIN_LOG_LEVEL=3 "$JPY" -m \
          "tensorflow_probability.substrates.$s.distributions.$t" 2>&1 || true)
    echo "$s $t: $(echo "$out" | grep -E '^(Ran|OK|FAILED)' | tr '\n' ' ')" \
      | tee -a "$RES/substrate-tests.log"
  done
done
