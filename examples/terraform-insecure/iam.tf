# INSECURE: triggers TF-IAM-001
# IAM policy with wildcard action and resource (admin policy)

resource "aws_iam_policy" "admin_wildcard" {
  name        = "AdminWildcardPolicy"
  description = "Full admin access — overly permissive"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      }
    ]
  })
}

# INSECURE: triggers TF-IAM-002
# IAM role with wildcard principal in trust policy

resource "aws_iam_role" "open_trust" {
  name = "open-trust-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.open_trust.name
  policy_arn = aws_iam_policy.admin_wildcard.arn
}
