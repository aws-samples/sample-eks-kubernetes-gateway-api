# =============================================================================
# VPC Lattice Service Network and Route 53 Private Hosted Zone
# =============================================================================

# -----------------------------------------------------------------------------
# VPC Lattice Service Network
# -----------------------------------------------------------------------------
module "vpclattice_service_network" {
  #checkov:skip=CKV_TF_1:Version pinning is sufficient for a sample; commit hash pinning is a production concern
  source  = "aws-ia/amazon-vpc-lattice-module/aws"
  version = "1.1.0"

  service_network = {
    name                  = "${var.project_prefix}-service-network"
    auth_type             = "AWS_IAM"
    access_log_cloudwatch = aws_cloudwatch_log_group.service_network_loggroup.arn

    auth_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = "*"
        Resource  = "*"
        Action    = "*"
        Condition = {
          StringNotEqualsIgnoreCase = {
            "aws:PrincipalType" = "anonymous"
          }
        }
      }]
    })
  }
}

resource "aws_cloudwatch_log_group" "service_network_loggroup" {
  #checkov:skip=CKV_AWS_158:KMS encryption adds cost and complexity not relevant to this Gateway API sample
  #checkov:skip=CKV_AWS_338:7-day retention is sufficient for a sample; increase for production
  name              = "/aws/vpc-lattice/${var.project_prefix}-service-network"
  retention_in_days = 7
}

# -----------------------------------------------------------------------------
# Route 53 — Private Hosted Zone
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "private_hz" {
  name = var.private_hosted_zone_name

  vpc {
    vpc_id = module.frontend_vpc.vpc_attributes.id
  }

  tags = {
    Name = "${var.project_prefix}-private-zone"
  }
}
