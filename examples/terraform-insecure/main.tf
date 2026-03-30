terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# This configuration intentionally contains security misconfigurations
# for use with the IaC Security Scanner demo.
#
# Expected findings:
#   TF-NET-001 — wide_open, web (2x) — open security group
#   TF-IAM-001 — admin_wildcard     — wildcard IAM policy
#   TF-IAM-002 — open_trust         — wildcard principal in trust policy
#   TF-STG-001 — public_assets, public_uploads (2x) — public S3 ACL
#   TF-STG-002 — unencrypted_data, logs (2x) — no S3 encryption
#   TF-CMP-001 — bastion, app_server (2x)    — public IP on EC2
#   TF-CMP-002 — app (launch template)        — IMDSv1 enabled
#
# Total: ~11 findings
