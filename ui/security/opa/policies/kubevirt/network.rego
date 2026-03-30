package kubevirt.network

import rego.v1

# KV-NET-001: VirtualMachine interface with masquerade binding lacks network policy
findings contains finding if {
    resource := input.resource
    resource.tool == "kubevirt"
    resource.type == "VirtualMachine"
    some iface in resource.attributes.spec.template.spec.domain.devices.interfaces
    iface.masquerade != null
    finding := {
        "id": "KV-NET-001",
        "severity": "medium",
        "category": "network",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "VirtualMachine interface with masquerade binding lacks network policy",
        "description": concat("", ["VirtualMachine '", resource.name, "' has a network interface with masquerade binding. Without a NetworkPolicy, the VM's pod network is unrestricted."]),
        "remediation": "Create a NetworkPolicy restricting ingress and egress to the VM's pod to only the required ports and sources.",
        "confidence": 0.8,
    }
}
