"""Generate privileged_users inputs and the expected 7.1/7.2/7.3 results.

Inputs (written to cases.json):
  * exhaustive: every tenant of 0-3 privileged accounts, where each account has
      display name  in {"A", "B", null, <key absent>}
      roles         in {[GA], [User Admin], [User Admin, GA], []}
      on-prem id    in {null, "x"}        (non-null = federated account)
    32 combinations per account, 1 + 32 + 32^2 + 32^3 = 33,825 tenants;
  * random: 4,000 tenants of 0-14 accounts whose names are drawn from only
    {"A", "B"}, so duplicate names are the norm and the 8/9 Global Admin
    boundary of MS.AAD.7.1v1 is crossed many times (fixed seed 2541).

Oracle (written to oracle.json) restates the baseline policies directly,
counting accounts by their object ID (the key of privileged_users):
  7.1  passes iff 2 <= #Global Admins <= 8
  7.2  passes iff 7.1 passes and #Global Admins <= #other privileged users
  7.3  passes iff no privileged account is federated
"""
import itertools
import json
import random
import sys

GA = "Global Administrator"
NAMES = ["A", "B", None, "<absent>"]
ROLES = [[GA], ["User Administrator"], ["User Administrator", GA], []]
ONPREM = [None, "x"]


def tenant(accounts):
    users = {}
    for i, (name, roles, onprem) in enumerate(accounts):
        user = {"roles": roles, "OnPremisesImmutableId": onprem}
        if name != "<absent>":
            user["DisplayName"] = name
        users[f"16b4d5c2-71c9-4644-8728-{i:012d}"] = user
    return {"privileged_users": users}


def oracle(case):
    users = list(case["privileged_users"].values())
    ga = sum(GA in u["roles"] for u in users)
    fed = sum(u["OnPremisesImmutableId"] is not None for u in users)
    t71 = 2 <= ga <= 8
    return {"ga": ga, "nga": len(users) - ga, "fed": fed,
            "t71": t71, "t72": t71 and ga <= len(users) - ga, "t73": fed == 0}


def main(outdir):
    attrs = list(itertools.product(NAMES, ROLES, ONPREM))
    cases = [tenant(spec) for n in range(4)
             for spec in itertools.product(attrs, repeat=n)]
    rng = random.Random(2541)
    for _ in range(4000):
        n = rng.randint(0, 14)
        cases.append(tenant([(rng.choice(["A", "B"]), rng.choice(ROLES),
                              rng.choice(ONPREM)) for _ in range(n)]))
    json.dump({"cases": cases}, open(f"{outdir}/cases.json", "w"))
    json.dump([oracle(c) for c in cases], open(f"{outdir}/oracle.json", "w"))
    print(f"{len(cases)} cases")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
