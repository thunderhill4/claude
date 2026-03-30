package terraform.compute

import rego.v1

# TF-CMP-001: EC2 instance with public IP association
findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_instance"
    resource.attributes.associate_public_ip_address == true
    finding := {
        "id": "TF-CMP-001",
        "severity": "medium",
        "category": "compute",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "EC2 instance with public IP association",
        "description": "The EC2 instance is configured to associate a public IP address, directly exposing it to the internet.",
        "remediation": "Set associate_public_ip_address to false and use a load balancer or NAT gateway for internet-facing traffic.",
        "confidence": 0.9,
    }
}

# TF-CMP-002: EC2 metadata service v1 enabled (IMDSv1)
findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_launch_template"
    resource.attributes.metadata_options != null
    opts := resource.attributes.metadata_options
    opts.http_tokens != "required"
    finding := {
        "id": "TF-CMP-002",
        "severity": "high",
        "category": "compute",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "EC2 metadata service v1 enabled (IMDSv1)",
        "description": "The launch template does not require IMDSv2 (http_tokens != required), leaving instances vulnerable to SSRF attacks that can steal IAM credentials via the metadata endpoint.",
        "remediation": "Set metadata_options.http_tokens to 'required' to enforce IMDSv2.",
        "confidence": 0.95,
    }
}
