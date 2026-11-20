# Ghidra: keep register-save stack slots mapped when a direct pointer escapes

**Status:** [PR #10235](https://github.com/NationalSecurityAgency/ghidra/pull/10235) opened 2026-11-17, assigned to the decompiler maintainer on 2026-11-18, awaiting review.
**Issue:** [NationalSecurityAgency/ghidra#9728](https://github.com/NationalSecurityAgency/ghidra/issues/9728), incorrect decompilation of ARM Thumb functions that use `push r7` to allocate local variables.
**Fix, tests and verification:** William Chuang (Logarchéon Inc.), with Claude (Anthropic) as coding assistant.

## The bug

Some ARM Thumb compilers (reported for IAR and Keil MDK) reserve space for local
variables by pushing registers instead of subtracting from `sp`:

```asm
my_function:
  push {r7, lr}        ; the slot written by "push r7" becomes a local int
  movs r0, #1
  str  r0, [sp, #0]    ; value = 1
  mov  r0, sp
  bl   some_function   ; some_function(&value)
  pop  {r0, pc}        ; return value
```

The equivalent C is `int value = 1; some_function(&value); return value;`.
Ghidra's decompiler printed this on current `master`:

```c
xunknown4 my_function(void)
{
  int4 aiStack_208 [128];

  some_function(aiStack_208 + 0x80);
  return 1;
}
```

The function returns whatever `some_function` left in `value`, not the constant 1,
and the 128-element array does not exist.

**Root cause.** `ActionRestrictLocal` (`coreaction.cc`) sees `r7`, a register the
function never changes, copied into the stack and treats that slot as register-save
storage: it calls `ScopeLocal::markNotMapped()` on it. For an unmapped stack slot,
`ScopeLocal::isUnmappedUnaliased()` reports that no pointer can reach it. The
constant stored in the slot is therefore propagated across the call, even though
the call receives a pointer to the slot.

## The fix

[`fix.patch`](fix.patch) (3 files, +104), the content of PR #10235 (commit `1cd1dc0`):

- `cpp/coreaction.cc`, `cpp/coreaction.hh` (+51): before marking a save slot as not
  mapped, `ActionRestrictLocal` collects every pointer into the stack that is the
  stack pointer plus a constant offset (an `AliasChecker` pass, run once and only
  when a save slot is found). If such a pointer starts inside the slot, the slot also
  holds a local variable and stays mapped, so ordinary alias analysis applies.
- Pointers built with a variable index are excluded. The existing test
  `stackcorner.xml` (`arraybottom`, x86-64) writes through `rsp + rbx*4 + 0x44`,
  whose constant part lands on the saved-`rbx` slot. That is an array access with a
  negative index, not a pointer to the slot; counting it breaks `Stack corner #3`
  (shown by the ablation below).
- `datatests/escapedstackslot.xml` (+53): a new regression test with 9 checks,
  based on the test proposed in the issue.

**Why genuine saves are unaffected.** In an ordinary prologue, pointers to local
variables point below the saved registers, never into them. The GCC frame-pointer
prologue `push {r7,lr}; add r7,sp,#0` is the one ordinary case where a pointer lands
exactly on the `r7` slot; it is part of the new test and of the prologue check, and
its output is unchanged.

## Verification

Run `./reproduce.sh`. On Linux it needs `git`, `make`, `g++` and the BFD headers
(`binutils-dev`); on macOS it needs Docker and reruns itself in an Ubuntu 24.04
container, because the decompiler Makefile has no macOS arm64 support. It checks out
Ghidra `master` at `66b3412` (2026-11-19), compiles the SLEIGH specification of every
processor, builds the decompiler test harness, and runs everything below on the
unmodified code and with the fix (about 3 minutes on a 2-core Linux machine). Outputs
are written to [`results/`](results/).

| Check | Unmodified `master` | With the fix |
|---|---|---|
| Complete decompiler datatest suite | 760/760 | **769/769** (760 existing + 9 new) |
| Decompiler unit tests | 205/205 | **205/205** |
| New regression test `escapedstackslot.xml` | 3 of 9 checks pass | **9 of 9** |
| Reporter's `my_function` | `return 1;`, phantom `[128]` array | **`return iStack_8;`** |
| Reporter's `my_function2`, three-pointer call | third argument `(int4 *)((int4)register_sp + -8)` | **`&iStack_8`** |
| Reporter's `my_function3` | phantom `aiStack_210 [128]` | **`some_function(&iStack_10);`** |
| Five ordinary ARM prologues | reference output | **identical** |
| Ablation: count indexed pointers too | | `Stack corner #3` fails (768/769) |

Decompiled C with the fix, from [`results/bug-cases-fixed.txt`](results/bug-cases-fixed.txt):

```c
int4 my_function(void)
{
  int4 iStack_8;

  iStack_8 = 1;
  some_function(&iStack_8);
  return iStack_8;
}
```

### The checks

- **Reporter's examples** ([`checks/bug-cases.xml`](checks/bug-cases.xml),
  [`checks/bug-case-three-pointers.xml`](checks/bug-case-three-pointers.xml)): the
  three functions from the issue, assembled from [`checks/bug-cases.s`](checks/bug-cases.s).
  `bug-cases.xml` declares only `some_function(int4 *)`, as in the original report.
  The three-pointer file uses the reporter's prototypes for the second example,
  `int my_function2(void)` and `some_function(int *, int *, int *)`; its third
  pointer, `sp+8`, points at the slot written by `push r7`.
- **Ordinary prologues** ([`checks/prologues.xml`](checks/prologues.xml), source
  [`checks/prologues.s`](checks/prologues.s)): GCC `-O0` with a frame pointer; a frame
  pointer onto the `r7` save slot; a `sub sp` buffer with callee-saved `r4`/`r5`; a
  callee-saved `r4`; and `push {r4-r7,lr}` with `add r7,sp,#12`. The decompiled C
  must be byte-identical before and after the fix
  ([`results/prologues-diff.log`](results/prologues-diff.log)).
- **New regression test on unmodified code**: the PR's `escapedstackslot.xml` is run
  without the code change, to show that it detects the bug (6 of its 9 checks fail).
- **Ablation** ([`checks/ablation-count-indexed.patch`](checks/ablation-count-indexed.patch)):
  removes the one line that skips indexed pointers. The complete suite then fails
  `Stack corner #3`, which shows the exclusion is required.
- **Printing the decompiled C** ([`checks/dump-output.patch`](checks/dump-output.patch)):
  a three-line change to the test harness, used only by this kit, that prints the
  decompiler's output when `DUMPOUT=1` is set. It is not part of the PR.

### Not covered

- Only the C++ decompiler was run, through its own test harness. The Ghidra
  application (Java, GUI, analysis of complete firmware images) was not run.
- The reporter's further example in the issue thread, a removed `if` block
  (`missing_if.xml`, a decompiler debug file attached to the issue), was not run.
- The macOS path of `reproduce.sh` (Docker) was not run for the results recorded
  here; they come from Linux x86_64 (Ubuntu 24.04, GCC 13).
- The PR's datatest declares a one-pointer `some_function`; the three-pointer form
  of `my_function2` is checked by this kit only.

## Files

```
fix.patch                              the change submitted as PR #10235
reproduce.sh                           builds Ghidra's decompiler, runs every check, writes results/
checks/bug-cases.xml, bug-cases.s      the reporter's examples and their assembly source
checks/bug-case-three-pointers.xml     the reporter's my_function2 with its three-pointer prototype
checks/prologues.xml, prologues.s      five ordinary prologues that must not change
checks/dump-output.patch               test-harness change that prints the decompiled C
checks/ablation-count-indexed.patch    removes the indexed-pointer exclusion
results/                               summaries and decompiled output from the run recorded here
```
