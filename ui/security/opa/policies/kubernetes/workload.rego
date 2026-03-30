package kubernetes.workload

import rego.v1

workload_types := {"Pod", "Deployment", "StatefulSet", "DaemonSet"}

# K8S-WRK-001a: Container with runAsNonRoot explicitly set to false
findings contains finding if {
    resource := input.resource
    resource.type in workload_types
    some container in resource.attributes.spec.containers
    container.securityContext.runAsNonRoot == false
    finding := {
        "id": "K8S-WRK-001",
        "severity": "high",
        "category": "workload",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Container running as root user",
        "description": concat("", ["Container '", container.name, "' has runAsNonRoot set to false, allowing it to run as the root user."]),
        "remediation": "Set securityContext.runAsNonRoot: true and securityContext.runAsUser to a non-zero UID (e.g., 1000).",
        "confidence": 0.95,
    }
}

# K8S-WRK-001b: Container with runAsUser explicitly set to 0 (root)
findings contains finding if {
    resource := input.resource
    resource.type in workload_types
    some container in resource.attributes.spec.containers
    container.securityContext.runAsUser == 0
    finding := {
        "id": "K8S-WRK-001",
        "severity": "high",
        "category": "workload",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Container running as root user",
        "description": concat("", ["Container '", container.name, "' has runAsUser set to 0 (root)."]),
        "remediation": "Set securityContext.runAsUser to a non-zero UID (e.g., 1000) and securityContext.runAsNonRoot: true.",
        "confidence": 1.0,
    }
}

# K8S-WRK-002: Container running in privileged mode
findings contains finding if {
    resource := input.resource
    resource.type in workload_types
    some container in resource.attributes.spec.containers
    container.securityContext.privileged == true
    finding := {
        "id": "K8S-WRK-002",
        "severity": "critical",
        "category": "workload",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Container running in privileged mode",
        "description": concat("", ["Container '", container.name, "' is running in privileged mode, granting it nearly all capabilities of the host kernel."]),
        "remediation": "Remove securityContext.privileged: true and grant only the specific capabilities required using securityContext.capabilities.add.",
        "confidence": 1.0,
    }
}

# K8S-WRK-003: Pod using host network namespace
findings contains finding if {
    resource := input.resource
    resource.type in workload_types
    resource.attributes.spec.hostNetwork == true
    finding := {
        "id": "K8S-WRK-003",
        "severity": "high",
        "category": "workload",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Pod using host network namespace",
        "description": "The pod is configured to use the host network namespace, allowing it to bind to host ports and sniff host network traffic.",
        "remediation": "Remove hostNetwork: true from the pod spec unless absolutely necessary. Use pod-level networking with explicit port declarations instead.",
        "confidence": 1.0,
    }
}
