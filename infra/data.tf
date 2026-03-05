# =============================================================================
# Shared Data Sources
# =============================================================================

# Current caller identity and resolved IAM principal (for EKS admin access entries)
data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# VPC Lattice managed prefix list (used by backend cluster security groups)
data "aws_ec2_managed_prefix_list" "vpc_lattice" {
  name = "com.amazonaws.${var.aws_region}.vpc-lattice"
}
