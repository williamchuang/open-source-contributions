package harness
import rego.v1
Summary := {
    "ga": count(data.aad.GlobalAdmins),
    "nga": count(data.aad.NotGlobalAdmins),
    "fed": count(data.aad.FederatedAdmins),
    "t71": [t.RequirementMet | some t in data.aad.tests; t.PolicyId == "MS.AAD.7.1v1"][0],
    "t72": [t.RequirementMet | some t in data.aad.tests; t.PolicyId == "MS.AAD.7.2v1"][0],
    "t73": [t.RequirementMet | some t in data.aad.tests; t.PolicyId == "MS.AAD.7.3v1"][0],
    "n71": [t.ReportDetails | some t in data.aad.tests; t.PolicyId == "MS.AAD.7.1v1"][0],
}
Results := {sprintf("%d", [I]): S | some I, C in data.cases; S := Summary with input as C}
