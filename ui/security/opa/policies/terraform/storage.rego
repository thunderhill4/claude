package terraform.storage

import rego.v1

# TF-STG-001: S3 bucket with public ACL (public-read)
findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_s3_bucket"
    resource.attributes.acl == "public-read"
    finding := {
        "id": "TF-STG-001",
        "severity": "high",
        "category": "storage",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "S3 bucket with public ACL",
        "description": "The S3 bucket ACL is set to 'public-read', allowing any unauthenticated user to read bucket contents.",
        "remediation": "Set the bucket ACL to 'private' and use bucket policies or IAM policies to grant specific access.",
        "confidence": 1.0,
    }
}

# TF-STG-001b: S3 bucket with public ACL (public-read-write)
findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_s3_bucket"
    resource.attributes.acl == "public-read-write"
    finding := {
        "id": "TF-STG-001",
        "severity": "high",
        "category": "storage",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "S3 bucket with public ACL",
        "description": "The S3 bucket ACL is set to 'public-read-write', allowing any unauthenticated user to read and write bucket contents.",
        "remediation": "Set the bucket ACL to 'private' and use bucket policies or IAM policies to grant specific access.",
        "confidence": 1.0,
    }
}

# TF-STG-002: S3 bucket without server-side encryption
findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_s3_bucket"
    resource.attributes.bucket != null
    not resource.attributes.server_side_encryption_configuration
    finding := {
        "id": "TF-STG-002",
        "severity": "medium",
        "category": "storage",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "S3 bucket without server-side encryption",
        "description": "The S3 bucket does not have server-side encryption configured, leaving data at rest unencrypted.",
        "remediation": "Enable server-side encryption using aws:kms or AES256 by adding a server_side_encryption_configuration block.",
        "confidence": 0.9,
    }
}
