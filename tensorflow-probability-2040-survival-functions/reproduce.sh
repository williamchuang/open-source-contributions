#!/usr/bin/env bash
# Reproduce every result for tensorflow/probability#2040 (PR #2043) from scratch.
# Needs: git, python3 (tested with 3.13). Runs on Linux x86_64; macOS arm64
# should work with the same pinned wheels.  CPU only.
#
#   ./reproduce.sh          reference values, sweeps, gradients, XLA and the
#                           five changed test files, on unmodified and fixed
#                           code (about 10 minutes after installation)
#   EXTENDED=1 ./reproduce.sh   adds TFP's randomized property and platform tests
#                           for the affected classes and the NumPy and JAX
#                           substrates (about 15 minutes more)
set -euo pipefail

BASE=df8c454f10495cc8584d0540e202911b61bce312   # tensorflow/probability main the fix was made on
PY="${PYTHON:-python3}"
KIT="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$KIT/work}"
RES="$KIT/results"
CHK="$KIT/checks"
D=tensorflow_probability/python/distributions
TESTS="chi2_test gamma_test beta_test binomial_test exponential_test"
mkdir -p "$WORK" "$RES"

# --- environment -------------------------------------------------------------
if [ ! -x "$WORK/venv-tf/bin/python" ]; then
  "$PY" -m venv "$WORK/venv-tf"
  "$WORK/venv-tf/bin/pip" install -q tensorflow==2.21.0 tf-keras==2.21.0 \
    numpy==2.5.5 scipy==1.18.1 mpmath==1.4.1 absl-py==2.5.1 \
    hypothesis==6.170.15 dm-tree==0.1.10 decorator==5.3.1 cloudpickle==3.1.3 \
    gast==0.7.0 pytest==9.2.0 pytest-timeout==2.4.0
fi
TPY="$WORK/venv-tf/bin/python"
"$TPY" -c 'import tensorflow as tf, scipy, mpmath; print("TensorFlow", tf.__version__, "| SciPy", scipy.__version__, "| mpmath", mpmath.__version__)'

if [ ! -d "$WORK/probability/.git" ]; then
  git init -q "$WORK/probability"
  git -C "$WORK/probability" remote add origin https://github.com/tensorflow/probability.git
fi
cd "$WORK/probability"
git fetch -q --depth 1 origin "$BASE"
git checkout -q --force "$BASE"
git clean -qfd
export PYTHONPATH="$WORK/probability" TF_CPP_MIN_LOG_LEVEL=3

run_tests() {  # $1 = output log; runs the five test files, keeps summaries and failures
  : > "$1"
  for t in $TESTS; do
    out=$("$TPY" "$D/$t.py" 2>&1 || true)
    echo "$t: $(echo "$out" | grep -E '^(Ran|OK|FAILED)' | tr '\n' ' ')" | tee -a "$1"
    { echo "$out" | grep -E '^FAIL: ' || true; } \
      | sed -E 's/ \(__main__.*//; s/_(eager_no_tf_function|eager|graph)$//' \
      | sort -u | sed 's/^/    /' | tee -a "$1"
  done
}

run_checks() {  # $1 = label
  "$TPY" "$CHK/reference_cases.py" "$1" "$RES/$1-reference-cases.json" | tee "$RES/$1-reference-cases.log"
  "$TPY" "$CHK/sweep.py" "$1" float64 "$RES/$1-sweep-float64.json" | tee "$RES/$1-sweep-float64.log"
  "$TPY" "$CHK/sweep.py" "$1" float32 "$RES/$1-sweep-float32.json" | tee "$RES/$1-sweep-float32.log"
  "$TPY" "$CHK/gradient_scan.py" scan "$1" "$RES/$1-gradients.json"
}

echo "== 1. Unmodified main ($BASE)"
run_checks main
echo "-- new tests on unmodified code"
git apply --include='*_test.py' "$KIT/fix.patch"
run_tests "$RES/new-tests-on-main.log"
git checkout -q -- .

echo "== 2. With the fix (fix.patch = PR #2043)"
git apply "$KIT/fix.patch"
git diff --stat | tail -1
run_checks fixed
"$TPY" "$CHK/gradient_scan.py" compare "$RES/main-gradients.json" "$RES/fixed-gradients.json" \
  | tee "$RES/gradient-comparison.log"
"$TPY" "$CHK/xla_check.py" | tee "$RES/xla.log"
echo "-- five test files with the fix"
run_tests "$RES/unit-tests-with-fix.log"

if [ "${EXTENDED:-0}" = 1 ]; then
  echo "== 3. Randomized property and platform tests (affected classes)"
  TFP_HYPOTHESIS_MAX_EXAMPLES=10 "$TPY" -m pytest -q -p no:cacheprovider --timeout=600 \
    $(cat "$CHK/property_test_ids.txt") 2>&1 | grep -E 'passed|failed|error' | tail -1 \
    | tee "$RES/property-tests.log"
  echo "== 4. NumPy and JAX substrates"
  PYTHON="$PY" bash "$CHK/substrates.sh" "$WORK/probability" "$WORK" "$RES"
fi
echo "Done. Results in $RES"
