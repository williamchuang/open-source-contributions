#!/usr/bin/env bash
# Reproduce every result for NationalSecurityAgency/ghidra#9728 (PR #10235) from scratch.
# Linux: needs git, make, g++, and the BFD headers (Debian/Ubuntu: apt install git make g++ binutils-dev).
# macOS: needs Docker; the script reruns itself in an Ubuntu 24.04 container, because the
#        decompiler Makefile has no macOS arm64 support.
# Takes about 3 minutes on a 2-core Linux machine (longer under Docker), mostly compiling the
# decompiler and every processor's SLEIGH specification.
set -euo pipefail

BASE=66b3412bdf679197c43858fabf7c3ea2f833bc31   # Ghidra master on 2026-11-19, the target of PR #10235

KIT="$(cd "$(dirname "$0")" && pwd)"

if [ "$(uname -s)" = Darwin ] && [ -z "${IN_DOCKER:-}" ]; then
  command -v docker >/dev/null || { echo "macOS needs Docker (https://www.docker.com/) to run this kit"; exit 1; }
  exec docker run --rm -e IN_DOCKER=1 -v "$KIT":/kit -w /kit ubuntu:24.04 bash -c \
    'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git make g++ binutils-dev >/dev/null && /kit/reproduce.sh'
fi

WORK="${WORK:-$KIT/work}"
mkdir -p "$WORK" "$KIT/results"
R="$KIT/results"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

# 0. Ghidra source at the PR's base commit
GH="$WORK/ghidra"
if [ ! -d "$GH/.git" ]; then
  git init -q "$GH"
  git -C "$GH" remote add origin https://github.com/NationalSecurityAgency/ghidra.git
  GIT_LFS_SKIP_SMUDGE=1 git -C "$GH" fetch -q --depth 1 origin "$BASE"
fi
cd "$GH"
git checkout -q --force "$BASE"
git clean -qfd -e '*.sla' -e '*.o' -e '*.d' -e 'sleigh_opt' -e 'decomp_test_dbg'
DEC=Ghidra/Features/Decompiler/src/decompile
CPP="$GH/$DEC/cpp"
git apply "$KIT/checks/dump-output.patch"       # lets DUMPOUT=1 print the decompiled C

# ARCH_TYPE is cleared so the Linux branch of the Makefile also builds on arm64 hosts.
build() { make -s -C "$CPP" -j"$JOBS" ARCH_TYPE= "$@"; }
TEST() { "$CPP/decomp_test_dbg" -sleighpath "$GH" "$@" || true; }   # exit code = number of failures
SUITE() { TEST -path "$GH/$DEC/datatests" datatests; }     # the complete datatest suite
summary() { grep -E "^(Total|FAIL)|^  [A-Za-z]" || true; }
show() {   # print the decompiled C of one check file in checks/
  local d; d="$(mktemp -d)"; cp "$KIT/checks/$1.xml" "$d/"
  DUMPOUT=1 TEST -path "$d" datatests 2>&1 | grep -vE '^(Success|Total|$)'; rm -rf "$d"
}

echo "== 0. Build the SLEIGH compiler and compile every processor specification"
build sleigh_opt
for d in "$GH"/Ghidra/Processors/*/data/languages; do
  "$CPP/sleigh_opt" -a "$d" >/dev/null 2>&1 || echo "  (sleigh: errors in $d)"
done
echo "  $(ls "$GH"/Ghidra/Processors/*/data/languages/*.sla | wc -l | tr -d ' ') .sla files"

echo "== 1. Unmodified master: decompiler test suite"
build decomp_test_dbg
SUITE 2>&1 | summary | tee "$R/datatests-main.log"
TEST unittests 2>&1 | tail -1 | tee "$R/unittests-main.log"

echo "== 2. Unmodified master: the reporter's examples and five ordinary prologues"
show bug-cases > "$R/bug-cases-main.txt"
show bug-case-three-pointers > "$R/bug-case-three-pointers-main.txt"
show prologues > "$R/prologues-main.txt"
grep -hE "return 1;|\[128\]|register_sp" "$R"/bug-case*-main.txt || true

echo "== 3. The PR's new test (escapedstackslot.xml) against unmodified master (expect failures)"
git apply --include="$DEC/datatests/*" "$KIT/fix.patch"
d="$(mktemp -d)"; cp "$DEC/datatests/escapedstackslot.xml" "$d/"
TEST -path "$d" datatests 2>&1 | grep -E "^(Success|FAIL|Total)" | tee "$R/new-test-on-main.log"
rm -rf "$d"; rm "$DEC/datatests/escapedstackslot.xml"

echo "== 4. Apply the fix (PR #10235) and rerun everything"
git apply "$KIT/fix.patch"
git diff --stat -- "$DEC/cpp/coreaction.cc" "$DEC/cpp/coreaction.hh" | tail -1
build decomp_test_dbg
SUITE 2>&1 | summary | tee "$R/datatests-fixed.log"
TEST unittests 2>&1 | tail -1 | tee "$R/unittests-fixed.log"
show bug-cases > "$R/bug-cases-fixed.txt"
show bug-case-three-pointers > "$R/bug-case-three-pointers-fixed.txt"
show prologues > "$R/prologues-fixed.txt"
if diff -q "$R/prologues-main.txt" "$R/prologues-fixed.txt" >/dev/null; then
  echo "prologues: identical output before and after the fix" | tee "$R/prologues-diff.log"
else
  echo "prologues: OUTPUT CHANGED" | tee "$R/prologues-diff.log"
  diff "$R/prologues-main.txt" "$R/prologues-fixed.txt" | tee -a "$R/prologues-diff.log"
fi

echo "== 5. Ablation: also count indexed pointers (expect 'Stack corner #3' to fail)"
git apply "$KIT/checks/ablation-count-indexed.patch"
build decomp_test_dbg
SUITE 2>&1 | summary | tee "$R/ablation-count-indexed.log"
git apply -R "$KIT/checks/ablation-count-indexed.patch"
build decomp_test_dbg

echo "Done. Results are in $R/"
