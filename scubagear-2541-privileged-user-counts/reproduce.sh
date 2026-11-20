#!/usr/bin/env bash
# Reproduce every result for cisagov/ScubaGear#2541 (PR #2595) from scratch.
# Needs: git, curl, python3. Runs on macOS (Intel/Apple silicon) and Linux x86_64.
# Takes a few minutes; the model check is the slow part (two runs of ~1 min).
set -euo pipefail

BASE=18f7930ebf663841c30c1806716dcb69c83f7977   # ScubaGear main the fix was made on
OPA_VERSION=1.20.2                              # ScubaGear's pinned OPA (ScubaConfigDefaults.json)
REGAL_VERSION=0.42.0                            # pinned in unit_test_opa.yaml

KIT="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$KIT/work}"
mkdir -p "$WORK/bin" "$KIT/results"
cd "$WORK"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  OPA_ASSET=opa_darwin_arm64_static; REGAL_ASSET=regal_Darwin_arm64 ;;
  Darwin-x86_64) OPA_ASSET=opa_darwin_amd64;        REGAL_ASSET=regal_Darwin_x86_64 ;;
  Linux-x86_64)  OPA_ASSET=opa_linux_amd64_static;  REGAL_ASSET=regal_Linux_x86_64 ;;
  *) echo "unsupported platform $(uname -sm)"; exit 1 ;;
esac
[ -x bin/opa ] || curl -sSfL -o bin/opa \
  "https://github.com/open-policy-agent/opa/releases/download/v$OPA_VERSION/$OPA_ASSET"
[ -x bin/regal ] || curl -sSfL -o bin/regal \
  "https://github.com/open-policy-agent/regal/releases/download/v$REGAL_VERSION/$REGAL_ASSET"
chmod +x bin/opa bin/regal
OPA="$WORK/bin/opa"; REGAL="$WORK/bin/regal"
"$OPA" version | head -1

if [ ! -d ScubaGear ]; then
  git clone -q https://github.com/cisagov/ScubaGear.git
fi
cd ScubaGear
git checkout -q --force "$BASE"
git clean -qfd
M=PowerShell/ScubaGear
REGO_TESTS() { "$OPA" test $M/Rego/*.rego $M/Rego/Utils/*.rego $M/Testing/Unit/Rego/*/*.rego "$@"; }

python3 "$KIT/model-check/gen_cases.py" "$WORK"

run_model_check() {  # $1 = label
  "$OPA" eval -d $M/Rego -d "$KIT/model-check/harness.rego" -d "$WORK/cases.json" \
    'data.harness.Results' -f raw > "$KIT/results/$1-results.json" 2>/dev/null
  python3 "$KIT/model-check/compare.py" "$WORK/oracle.json" "$KIT/results/$1-results.json" "$1"
  rm -f "$KIT/results/$1-results.json"   # large; the summary is kept
}

echo "== 1. Model check and lint on unmodified main ($BASE)"
run_model_check main
"$REGAL" lint $M/Rego $M/Testing --format compact 2>/dev/null \
  | sed -E 's/:[0-9]+(:[0-9]+)?//' | sort > "$WORK/regal-main.txt" || true

echo "== 2. New regression tests against the unmodified rules (expect all to FAIL)"
git apply --include="$M/Testing/*" "$KIT/fix.patch"
REGO_TESTS -r 'DisplayName' 2>&1 | grep -E "^(PASS|FAIL):|DisplayName" \
  | tee "$KIT/results/new-tests-on-main.log" || true
git checkout -q --force "$BASE"

echo "== 3. Apply the fix (PR #2595)"
git apply "$KIT/fix.patch"
git diff --stat | tail -1

echo "== 4. Strict compile, complete Rego unit suite, Regal lint"
"$OPA" check $M/Rego $M/Testing/Unit/Rego --strict && echo "opa check --strict: OK"
REGO_TESTS 2>&1 | tail -1 | tee "$KIT/results/unit-tests-with-fix.log"
"$REGAL" lint $M/Rego $M/Testing --format compact 2>/dev/null \
  | sed -E 's/:[0-9]+(:[0-9]+)?//' | sort > "$WORK/regal-fixed.txt" || true
if diff -q "$WORK/regal-main.txt" "$WORK/regal-fixed.txt" >/dev/null; then
  echo "regal: no new findings ($(wc -l < "$WORK/regal-fixed.txt") pre-existing on main, none added)" \
    | tee "$KIT/results/regal.log"
else
  echo "regal: findings differ from main:" | tee "$KIT/results/regal.log"
  diff "$WORK/regal-main.txt" "$WORK/regal-fixed.txt" | tee -a "$KIT/results/regal.log"
fi

echo "== 5. Model check with the fix"
run_model_check fixed

git checkout -q --force "$BASE"
echo "Done. Summaries are in $KIT/results/"
