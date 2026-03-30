package kubernetes.secrets

import rego.v1

# K8S-SEC-001: Kubernetes Secret with potentially sensitive data
findings contains finding if {
    resource := input.resource
    resource.type == "Secret"
    resource.attributes.data != null
    finding := {
        "id": "K8S-SEC-001",
        "severity": "medium",
        "category": "secrets",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Kubernetes Secret with potentially sensitive data in plaintext",
        "description": "The Kubernetes Secret contains data fields. Secret values are base64-encoded (not encrypted) by default in etcd unless encryption at rest is configured.",
        "remediation": "Enable etcd encryption at rest, use a secrets management solution (e.g., Vault, AWS Secrets Manager), and avoid committing Secret manifests with data to version control.",
        "confidence": 0.7,
    }
}
