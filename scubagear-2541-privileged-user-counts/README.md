# ScubaGear: count section 7 privileged users by object ID, not display name

**Status:** [PR #2595](https://github.com/cisagov/ScubaGear/pull/2595) opened 2026-11-20, awaiting review.
**Issue:** [cisagov/ScubaGear#2541](https://github.com/cisagov/ScubaGear/issues/2541), reported by a member of the ScubaGear team.
**Fix, tests and verification:** William Chuang (Logarchéon Inc.), with Claude (Anthropic) as coding assistant, as disclosed in the PR.

## The bug

ScubaGear checks Microsoft 365 tenants against CISA's security baselines. Three
Entra ID policies count privileged accounts:

| Policy | Requirement |
|---|---|
| MS.AAD.7.1v1 | between 2 and 8 Global Administrators |
| MS.AAD.7.2v1 | no more Global Administrators than other privileged users |
| MS.AAD.7.3v1 | no privileged account synchronised from on-premises |

The Rego rules collected these accounts into sets of display names
(`GlobalAdmins contains User.DisplayName`). A Rego set keeps one copy of each
value, so two different accounts with the same display name became one entry.

- 9 Global Admins, two of them named alike, were counted as 8: **7.1 passed**
  when it should fail.
- 2 Global Admins with the same name were counted as 1: **7.1 failed** when it
  should pass.
- A Global Admin whose display name is `null` made **7.1 disappear from the
  results**: the report text is built with `concat`, which fails on `null`, so
  the whole rule is undefined.

## The fix

[`fix.patch`](fix.patch) (2 files, +93 −12), identical to PR #2595:

- `Rego/AADConfig.rego`: the three sets iterate `some Id, User in
  input.privileged_users`. ScubaGear's provider keys that object by Entra object
  ID, so each entry is labelled `"<DisplayName> (<ObjectId>)"`. Distinct accounts
  give distinct labels, and the report now names the exact account. The name is
  read with `object.get`, so an account without a name is still counted.
- `Testing/Unit/Rego/AAD/AADConfig_07_test.rego`: six regression tests for
  duplicate names (7.1 both directions, 7.2, 7.3), a `null` name and an absent
  name; existing expected report strings updated for the label.

**Why the counts are now exact:** every label ends in ` (<ObjectId>)`, and Entra
object IDs are GUIDs, which contain no parentheses. The object ID can therefore be
read back from the end of any label, so two accounts with different IDs never
share a label, and each set has exactly one entry per account.

## Verification

Run `./reproduce.sh` (macOS or Linux; needs `git`, `curl`, `python3`; about 3
minutes). It downloads ScubaGear's pinned OPA 1.20.2 and Regal 0.42.0, checks out
ScubaGear `main` at `18f7930`, and runs everything below on the unmodified code
and with the fix. Outputs are written to [`results/`](results/).

| Check | Unmodified `main` | With the fix |
|---|---|---|
| New regression tests (6) | all 6 fail | all 6 pass |
| Complete Rego unit suite | 987/987 | **993/993** |
| `opa check --strict` | clean | clean |
| Regal lint | 23 findings | same 23, none added |
| Model check, 37,825 inputs: mismatches | 18,994 | **0** |
| 7.1 false passes / false fails | 123 / 6,261 | **0 / 0** |
| 7.2 false passes / false fails | 785 / 422 | **0 / 0** |
| Inputs with no 7.1 result | 15,546 (all contain a `null` name) | **0** |

### Model check

There is no theorem prover for Rego, so the rules are checked against an
independent oracle on a large, systematically generated set of inputs
([`model-check/`](model-check/)):

- **Exhaustive:** every tenant of 0–3 privileged accounts, each account taking
  every combination of display name (`"A"`, `"B"`, `null`, absent), roles
  (Global Admin, another role, both, none) and on-premises status
  (cloud-only, federated). That is 33,825 tenants.
- **Random:** 4,000 tenants of 0–14 accounts with names drawn only from `"A"` and
  `"B"`, so duplicate names are the norm and the 8/9 boundary of 7.1 is crossed
  repeatedly (fixed seed 2541).
- **Oracle** (`gen_cases.py`): the baseline requirements restated in Python,
  counting accounts by object ID.
- **Harness** (`harness.rego`): evaluates ScubaGear's own rules on every input
  with `with input as`, collecting the three counts, the three verdicts and the
  7.1 report text. `compare.py` checks every case against the oracle.

The same harness run on unmodified `main` finds the bug in 18,994 inputs. This
shows the check is sensitive to exactly this class of error.

### Not covered

- No run against a live Microsoft 365 tenant. ScubaGear's functional test plans
  for 7.1–7.3 assert only the pass/fail result and key accounts by GUID, so
  they are unaffected by the label change.
- The PowerShell report generator was not run; it is the only place the new
  `Name (ObjectId)` text is displayed.

## Files

```
fix.patch                  the change submitted as PR #2595
reproduce.sh               downloads tools, runs every check, writes results/
model-check/gen_cases.py   input generator and oracle
model-check/harness.rego   evaluates ScubaGear's rules on every input
model-check/compare.py     compares results with the oracle
results/                   summaries and logs from the run recorded here
```
