# TRIBE v2: fix grouped-metric logging when `average_subjects=True`

**Status:** [PR #84](https://github.com/facebookresearch/tribev2/pull/84) opened 2026-11-18; Meta CLA signed (label `CLA Signed`); awaiting review.
**Issue:** reported as one of the smaller items in [facebookresearch/tribev2#78](https://github.com/facebookresearch/tribev2/issues/78).
**Fix, tests and verification:** William Chuang (Logarchéon Inc.), with AI coding assistance (Claude, Anthropic).

## The bug

TRIBE v2 is Meta FAIR's model that predicts fMRI brain responses to video, audio
and text. During validation and test it logs a Pearson correlation per subject
through a grouped metric (`subj_pearson`, `GroupedMetric(OnlinePearsonCorr)` in
`tribev2/grids/defaults.py`). At the end of each epoch,
`BrainModule.on_val_or_test_epoch_end` turns the numeric group ids into subject
names with `data.subject_id.predefined_mapping`.

In average-subject mode (`average_subjects=True`), `TribeExperiment` sets that
mapping to `None` on purpose (`tribev2/main.py`, line 363), because the data are
averaged over subjects. The epoch-end hook still calls `.items()` on it, so every
validation or test run in that mode stops with

```
AttributeError: 'NoneType' object has no attribute 'items'   (tribev2/pl_module.py:114)
```

## The fix

[`fix.patch`](fix.patch) (2 files, +61 −10), identical to PR #84 (commit `23a9c27`):

- `tribev2/pl_module.py`: build the id → name map once per call, treat a `None`
  mapping as empty, and log a group without a name under its numeric id
  (`val/subj_pearson/0`). With a mapping the logged names are unchanged
  (`val/subj_pearson/sub-01`, ...).
- `tests/test_pl_module.py` (new): two regression tests, one with named subjects
  and one with the mapping set to `None` as in average-subject mode.

## Verification

Run `./reproduce.sh` (macOS or Linux; needs `git` and Python 3.10–3.12; set
`PYTHON=` to choose the interpreter). It installs the real dependencies
(torch 2.6.0, neuralset 0.0.2, neuraltrain 0.0.2, Lightning 2.5) into a
private virtualenv, checks out tribev2 `main` at `af58661`, and runs everything
below on the unmodified code and with the fix. No GPU and no data are needed.
Outputs are written to [`results/`](results/).

| Check | Unmodified `main` | With the fix |
|---|---|---|
| `fix.patch` equals the PR #84 diff | — | yes |
| New regression tests (2) | 1 fails (`AttributeError`, line 114), 1 passes | **2 pass** |
| Real Lightning validation loop, named subjects | logs `sub-01`, `sub-02` | logs `sub-01`, `sub-02` (unchanged) |
| Real Lightning validation loop, `average_subjects` mapping `None` | `AttributeError` | **logs `val/subj_pearson/0`** |
| black (line length 88, from `pyproject.toml`) | 3 pre-existing diff lines in `pl_module.py` | same 3, none added; new test file clean |
| isort (profile black), pyflakes | — | clean |

### The two levels of test

- **Unit tests** ([`tests/test_pl_module.py`](fix.patch), part of the PR): call
  `on_val_or_test_epoch_end` directly with a stand-in grouped metric and record
  what is passed to `log_dict`. They pin the exact logged keys and that the
  metric is reset.
- **End-to-end check** ([`checks/lightning_epoch_end.py`](checks/lightning_epoch_end.py),
  not part of the PR): runs `Trainer.validate` with the real `BrainModule`, the
  real `neuraltrain` `GroupedMetric(OnlinePearsonCorr)` configured as in
  `defaults.py`, and Lightning's real logging. Only `validation_step` is
  replaced, so that synthetic predictions, targets and subject ids reach the
  metric without the fMRI data pipeline. The epoch-end hook, the metric and the
  logging are the code under test. This reproduces the crash on `main` through
  the same call path as a real run and shows that the logged metric names are
  correct with the fix.

### Not covered

- No training or evaluation run on real fMRI data (the datasets and the
  pretrained checkpoint are not needed to reach this code path, and were not
  used).
- Group ids are assumed to be integers, as in the existing code
  (`int(k)` is unchanged by this fix).

### Found along the way

`tribev2/pl_module.py` imports `lightning.pytorch`, but `lightning` is not listed
in the dependencies in `pyproject.toml`, and none of the declared dependencies
installs it. `pip install -e .` in a clean environment therefore fails at
`import tribev2.pl_module` with `ModuleNotFoundError: No module named
'lightning'`. `reproduce.sh` installs `lightning<2.6` explicitly.

## Files

```
fix.patch                        the change submitted as PR #84
reproduce.sh                     installs dependencies, runs every check, writes results/
checks/lightning_epoch_end.py    end-to-end check through a real Lightning validation loop
results/                         logs from the run recorded here (Linux x86_64, Python 3.12)
```
