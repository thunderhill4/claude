package terraform.iam

import rego.v1

# TF-IAM-001: IAM policy with wildcard permissions
findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_iam_policy"
    json_str := json.marshal(resource.attributes.policy)
    contains(json_str, "\"*\"")
    finding := {
        "id": "TF-IAM-001",
        "severity": "critical",
        "category": "iam",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "IAM policy with wildcard permissions",
        "description": "The IAM policy grants wildcard (*) permissions on actions and/or resources, violating the principle of least privilege.",
        "remediation": "Replace wildcard actions and resources with explicit, minimal permissions required for the intended use case.",
        "confidence": 0.9,
    }
}

# TF-IAM-002: IAM role with wildcard principal in trust policy
findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_iam_role"
    json_str := json.marshal(resource.attributes.assume_role_policy)
    contains(json_str, "\"*\"")
    finding := {
        "id": "TF-IAM-002",
        "severity": "high",
        "category": "iam",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "IAM role with wildcard principal in trust policy",
        "description": "The IAM role trust policy allows any principal (*) to assume this role, which could lead to privilege escalation.",
        "remediation": "Restrict the Principal in the trust policy to specific AWS accounts, services, or IAM entities.",
        "confidence": 0.9,
    }
}
