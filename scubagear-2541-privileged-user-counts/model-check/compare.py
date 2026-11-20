"""Compare OPA results for every generated case with the oracle.

usage: compare.py ORACLE_JSON RESULTS_JSON LABEL
Prints one summary line and writes LABEL-summary.json next to RESULTS_JSON.
A case "has no result" when the policy rules leave the 7.1-7.3 tests undefined
for that input (for example, the report concat failing on a null name).
"""
import json
import os
import sys

oracle_path, results_path, label = sys.argv[1:4]
oracle = json.load(open(oracle_path))
results = json.load(open(results_path))
n = len(oracle)
summary = {"label": label, "cases": n, "no_result": 0, "mismatches": 0,
           "t71_false_pass": 0, "t71_false_fail": 0,
           "t72_false_pass": 0, "t72_false_fail": 0,
           "count_mismatch": 0, "report_count_mismatch": 0}
for i, want in enumerate(oracle):
    got = results.get(str(i))
    if got is None:
        summary["no_result"] += 1
        continue
    if any(got[k] != want[k] for k in want):
        summary["mismatches"] += 1
    for t in ("t71", "t72"):
        if got[t] and not want[t]:
            summary[f"{t}_false_pass"] += 1
        if not got[t] and want[t]:
            summary[f"{t}_false_fail"] += 1
    if any(got[k] != want[k] for k in ("ga", "nga", "fed")):
        summary["count_mismatch"] += 1
    if not got["n71"].startswith(f"{got['ga']} global admin"):
        summary["report_count_mismatch"] += 1
json.dump(summary, open(os.path.join(os.path.dirname(results_path),
                                     f"{label}-summary.json"), "w"), indent=2)
print(f"{label:>8}: {n} cases | no result {summary['no_result']} | "
      f"mismatches {summary['mismatches']} | 7.1 false pass "
      f"{summary['t71_false_pass']} / false fail {summary['t71_false_fail']} | "
      f"7.2 false pass {summary['t72_false_pass']} / false fail "
      f"{summary['t72_false_fail']}")
