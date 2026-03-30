package kubevirt.vm

import rego.v1

# KV-VM-001: VirtualMachine using mutable latest image tag
findings contains finding if {
    resource := input.resource
    resource.tool == "kubevirt"
    resource.type == "VirtualMachine"
    some disk in resource.attributes.spec.template.spec.domain.devices.disks
    disk.bootOrder == 1
    some vol in resource.attributes.spec.template.spec.volumes
    vol.name == disk.name
    contains(vol.containerDisk.image, ":latest")
    finding := {
        "id": "KV-VM-001",
        "severity": "medium",
        "category": "vm",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "VirtualMachine using mutable latest image tag",
        "description": concat("", ["VirtualMachine '", resource.name, "' boot disk uses a ':latest' container disk image tag, which is mutable and can change unexpectedly."]),
        "remediation": "Pin the container disk image to a specific immutable tag (e.g., ':v1.2.3' or a digest) to ensure reproducible VM deployments.",
        "confidence": 1.0,
    }
}

# KV-VM-002: VirtualMachine with dedicated CPU but no CPU request
findings contains finding if {
    resource := input.resource
    resource.tool == "kubevirt"
    resource.type == "VirtualMachine"
    resource.attributes.spec.template.spec.domain.cpu.dedicatedCpuPlacement == true
    not resource.attributes.spec.template.spec.domain.resources.requests.cpu
    finding := {
        "id": "KV-VM-002",
        "severity": "low",
        "category": "vm",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "VirtualMachine with dedicated CPU but no CPU request",
        "description": concat("", ["VirtualMachine '", resource.name, "' has dedicatedCpuPlacement enabled but no CPU resource request defined, which may cause scheduling failures."]),
        "remediation": "Add a resources.requests.cpu value to the domain spec matching the number of dedicated vCPUs configured.",
        "confidence": 0.9,
    }
}
