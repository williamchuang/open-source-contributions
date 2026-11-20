#!/usr/bin/env bash
# Reproduce every result for facebookresearch/tribev2 PR #84 from scratch.
# Needs: git and Python 3.10-3.12 (set PYTHON=... to choose one).
# Installs the real dependencies (torch 2.6.0, neuralset, neuraltrain, Lightning)
# into a private virtualenv under work/. On Linux the default torch wheel pulls
# about 3 GB of CUDA libraries; nothing here needs a GPU.
set -euo pipefail

BASE=af58661791a351a448a489042a28f6c37e1c14b7   # tribev2 main the fix was made on
PR_HEAD=23a9c27e0f04c9cc18d2c04608571c00851e22ff  # head of PR #84

KIT="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$KIT/work}"
PYTHON="${PYTHON:-python3}"
mkdir -p "$WORK" "$KIT/results"
cd "$WORK"

if [ ! -d tribev2 ]; then
  git clone -q https://github.com/facebookresearch/tribev2.git
fi
cd tribev2
git fetch -q origin "pull/84/head"
git checkout -q --force "$BASE"
git clean -qfd

echo "== 0. fix.patch is the change in PR #84"
diff <(git diff "$BASE" "$PR_HEAD" | grep -v '^index') <(grep -v '^index' "$KIT/fix.patch") \
  && echo "fix.patch == PR #84 ($PR_HEAD)" | tee "$KIT/results/patch-identity.log"

echo "== 1. Environment"
[ -x "$WORK/venv/bin/python" ] || "$PYTHON" -m venv "$WORK/venv"
PY="$WORK/venv/bin/python"
"$PY" -m pip install -q --upgrade pip
"$PY" -m pip install -q "torch==2.6.0"
"$PY" -m pip install -q -e . "lightning<2.6" torchmetrics pytest black isort pyflakes
{
  "$PY" --version
  "$PY" -m pip freeze | grep -iE '^(torch|lightning|torchmetrics|neuralset|neuraltrain|exca|numpy|pytest|black|isort)=='
  uname -sm
} | tee "$KIT/results/environment.txt"

echo "== 2. New regression tests against unmodified main (expect 1 fail, 1 pass)"
git apply --include='tests/*' "$KIT/fix.patch"
"$PY" -m pytest -q -p no:cacheprovider tests/test_pl_module.py 2>&1 \
  | grep -E "passed|failed|^E .*Error|^tribev2/.*Error" | tee "$KIT/results/new-tests-on-main.log" || true

echo "== 3. Lightning check on unmodified main (expect the average_subjects case to fail)"
"$PY" "$KIT/checks/lightning_epoch_end.py" 2>/dev/null \
  | tee "$KIT/results/lightning-on-main.log" || true
"$PY" -m black -q --diff tribev2/pl_module.py | grep -E '^[+-][^+-]' > "$WORK/black-main.txt" || true
git checkout -q --force "$BASE"; git clean -qfd

echo "== 4. Apply the fix (PR #84)"
git apply "$KIT/fix.patch"
git apply --stat "$KIT/fix.patch" | tail -1

echo "== 5. Tests with the fix (expect 2 passed)"
"$PY" -m pytest -q -p no:cacheprovider tests/test_pl_module.py 2>&1 \
  | grep -E "passed|failed" | tee "$KIT/results/tests-with-fix.log"

echo "== 6. Lightning check with the fix (expect both cases ok)"
"$PY" "$KIT/checks/lightning_epoch_end.py" 2>/dev/null | tee "$KIT/results/lightning-with-fix.log"

echo "== 7. Style: black (line length 88), isort (profile black), pyflakes"
{
  "$PY" -m black -q --check tests/test_pl_module.py && echo "black: tests/test_pl_module.py clean"
  "$PY" -m black -q --diff tribev2/pl_module.py | grep -E '^[+-][^+-]' > "$WORK/black-fixed.txt" || true
  if diff -q "$WORK/black-main.txt" "$WORK/black-fixed.txt" >/dev/null; then
    echo "black: tribev2/pl_module.py has $(wc -l < "$WORK/black-fixed.txt" | tr -d ' ') pre-existing diff lines on main, none added"
  else
    echo "black: tribev2/pl_module.py differs from main:"; diff "$WORK/black-main.txt" "$WORK/black-fixed.txt"
  fi
  "$PY" -m isort -q --check-only tests/test_pl_module.py tribev2/pl_module.py && echo "isort: clean"
  "$PY" -m pyflakes tests/test_pl_module.py tribev2/pl_module.py && echo "pyflakes: clean"
} | tee "$KIT/results/style.log"

git checkout -q --force "$BASE"; git clean -qfd
echo "Done. Logs are in $KIT/results/"
