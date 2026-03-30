# INSECURE: triggers TF-STG-001
# S3 bucket with public-read ACL

resource "aws_s3_bucket" "public_assets" {
  bucket = "my-public-assets-bucket"
  acl    = "public-read"

  tags = {
    Environment = "production"
  }
}

# INSECURE: triggers TF-STG-001 (public-read-write)
resource "aws_s3_bucket" "public_uploads" {
  bucket = "my-public-uploads-bucket"
  acl    = "public-read-write"
}

# INSECURE: triggers TF-STG-002
# S3 bucket with no server-side encryption

resource "aws_s3_bucket" "unencrypted_data" {
  bucket = "my-unencrypted-data-bucket"

  tags = {
    Name        = "unencrypted-data"
    Environment = "production"
    DataClass   = "sensitive"
  }
}

# Logging bucket — also unencrypted
resource "aws_s3_bucket" "logs" {
  bucket = "my-access-logs"
}
