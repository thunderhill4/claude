package terraform.network


findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_security_group"
    ingress := resource.attributes.ingress[_]
    ingress.cidr_blocks[_] == "0.0.0.0/0"
    ingress.from_port == 0
    ingress.to_port == 0
    finding := {
        "id": "TF-NET-001",
        "severity": "critical",
        "category": "network",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Unrestricted ingress on all ports",
        "description": "Security group allows unrestricted inbound traffic (0.0.0.0/0) on all ports.",
        "remediation": "Restrict ingress rules to specific CIDR ranges and required ports only.",
        "confidence": 1.0,
    }
}
