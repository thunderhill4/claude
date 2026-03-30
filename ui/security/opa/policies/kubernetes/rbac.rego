package kubernetes.rbac

import rego.v1

# K8S-RBAC-001: ClusterRoleBinding grants access to unauthenticated users
findings contains finding if {
    resource := input.resource
    resource.type == "ClusterRoleBinding"
    some subj in resource.attributes.subjects
    subj.kind == "Group"
    subj.name == "system:unauthenticated"
    finding := {
        "id": "K8S-RBAC-001",
        "severity": "critical",
        "category": "rbac",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "ClusterRoleBinding grants access to unauthenticated users",
        "description": "The ClusterRoleBinding grants permissions to the 'system:unauthenticated' group, allowing any unauthenticated request to use those permissions.",
        "remediation": "Remove the 'system:unauthenticated' subject from the ClusterRoleBinding and require proper authentication for all API access.",
        "confidence": 1.0,
    }
}

# K8S-RBAC-002: ClusterRole with wildcard verbs and resources
findings contains finding if {
    resource := input.resource
    resource.type == "ClusterRole"
    some rule in resource.attributes.rules
    some v in rule.verbs
    v == "*"
    some res in rule.resources
    res == "*"
    finding := {
        "id": "K8S-RBAC-002",
        "severity": "critical",
        "category": "rbac",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "ClusterRole with wildcard verbs and resources",
        "description": "The ClusterRole grants wildcard (*) verbs on wildcard (*) resources, effectively granting full cluster access to any bound subject.",
        "remediation": "Replace wildcard permissions with specific verbs and resource types following the principle of least privilege.",
        "confidence": 1.0,
    }
}
