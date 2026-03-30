package registry.images

import rego.v1

# REG-IMG-001: Container image using mutable latest tag
findings contains finding if {
    resource := input.resource
    resource.tool == "registry"
    resource.type == "image"
    resource.attributes.is_mutable_tag == true
    finding := {
        "id": "REG-IMG-001",
        "severity": "medium",
        "category": "registry",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Container image using mutable latest tag",
        "description": concat("", ["Image '", resource.name, "' uses a mutable tag (e.g., ':latest'). Mutable tags can resolve to different image digests over time, making deployments non-reproducible."]),
        "remediation": "Pin images to specific immutable tags or use image digests (sha256:...) to ensure reproducible deployments.",
        "confidence": 1.0,
    }
}

# REG-IMG-002: Container image with no tags (orphaned)
findings contains finding if {
    resource := input.resource
    resource.tool == "registry"
    resource.type == "image"
    resource.attributes.tag_count == 0
    finding := {
        "id": "REG-IMG-002",
        "severity": "low",
        "category": "registry",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Container image with no tags",
        "description": concat("", ["Image '", resource.name, "' has no tags and is potentially orphaned. Untagged images may indicate stale or unused artifacts accumulating in the registry."]),
        "remediation": "Review and remove orphaned images using registry garbage collection, or tag images that are still in active use.",
        "confidence": 0.8,
    }
}
