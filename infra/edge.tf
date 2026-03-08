# =============================================================================
# Edge — VPC, EKS Cluster (Auto Mode), ECR Repositories (Frontend + BFF),
#         WAF WebACL, ALB via Gateway API, VPC Lattice Gateway API Controller,
#         BFF Pod Identity for SigV4 signing
# =============================================================================

# -----------------------------------------------------------------------------
# ECR Repositories
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "frontend" {
  #checkov:skip=CKV_AWS_136:KMS encryption adds cost and complexity not relevant to this Gateway API sample
  #checkov:skip=CKV_AWS_51:Mutable tags accepted for this sample — see security/report.html
  name                 = "${var.project_prefix}/frontend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "bff" {
  #checkov:skip=CKV_AWS_136:KMS encryption adds cost and complexity not relevant to this Gateway API sample
  #checkov:skip=CKV_AWS_51:Mutable tags accepted for this sample — see security/report.html
  name                 = "${var.project_prefix}/bff"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "payments" {
  #checkov:skip=CKV_AWS_136:KMS encryption adds cost and complexity not relevant to this Gateway API sample
  #checkov:skip=CKV_AWS_51:Mutable tags accepted for this sample — see security/report.html
  name                 = "${var.project_prefix}/payments"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# =============================================================================
# CloudWatch log group (for Payments VPC Lattice service logs)
# =============================================================================

resource "aws_cloudwatch_log_group" "payments_service_loggroup" {
  #checkov:skip=CKV_AWS_158:KMS encryption adds cost and complexity not relevant to this Gateway API sample
  #checkov:skip=CKV_AWS_338:7-day retention is sufficient for a sample; increase for production
  name              = "/aws/vpc-lattice/${var.project_prefix}-payments-service"
  retention_in_days = 7
}

# =============================================================================
# EDGE VPC
# =============================================================================

module "edge_vpc" {
  #checkov:skip=CKV_TF_1:Version pinning is sufficient for a sample; commit hash pinning is a production concern
  source  = "aws-ia/vpc/aws"
  version = "= 4.7.3"

  name                                 = "${var.project_prefix}-edge-vpc"
  cidr_block                           = "10.0.0.0/16"
  vpc_assign_generated_ipv6_cidr_block = true
  az_count                             = 2

  vpc_lattice = {
    service_network_identifier = module.vpclattice_service_network.service_network.id
    security_group_ids         = [aws_security_group.vpclattice_association_edge_sg.id]
  }

  subnets = {
    public = {
      netmask                   = 24
      assign_ipv6_cidr          = true
      nat_gateway_configuration = "all_azs"
      tags = {
        "kubernetes.io/role/elb" = "1"
      }
    }
    private = {
      netmask                 = 24
      assign_ipv6_cidr        = true
      connect_to_public_natgw = true
      tags = {
        "kubernetes.io/role/internal-elb" = "1"
      }
    }
  }
}

# Security group for VPC Lattice service network VPC association
resource "aws_security_group" "vpclattice_association_edge_sg" {
  description = "Security group for VPC Lattice service network association"
  vpc_id      = module.edge_vpc.vpc_attributes.id

  tags = {
    Name = "${var.project_prefix}-lattice-edge-association-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "lattice_association_edge_ingress_eks" {
  security_group_id            = aws_security_group.vpclattice_association_edge_sg.id
  description                  = "Allow access from EKS cluster"
  ip_protocol                  = "tcp"
  from_port                    = var.vpclattice_protocol == "HTTPS" ? 443 : 80
  to_port                      = var.vpclattice_protocol == "HTTPS" ? 443 : 80
  referenced_security_group_id = aws_eks_cluster.edge.vpc_config[0].cluster_security_group_id
}

# =============================================================================
# EKS Edge Cluster (Auto Mode)
# =============================================================================
resource "aws_eks_cluster" "edge" {
  name     = "${var.project_prefix}-edge-cluster"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  #checkov:skip=CKV_AWS_38:Public endpoint intentionally open — deploy script runs from developer's local machine
  #checkov:skip=CKV_AWS_39:Public endpoint intentionally open — deploy script runs from developer's local machine
  #checkov:skip=CKV_AWS_58:Secrets encryption requires KMS key — adds complexity not relevant to this sample
  #checkov:skip=CKV_AWS_339:EKS 1.35 is supported; scanner may not recognise the latest versions

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode = "API"
  }

  bootstrap_self_managed_addons = false

  compute_config {
    enabled       = true
    node_pools    = ["general-purpose"]
    node_role_arn = aws_iam_role.eks_node_group.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = true
    subnet_ids              = [for k, v in module.edge_vpc.private_subnet_attributes_by_az : v.id if startswith(k, "private/")]
  }

  tags = {
    Name = "${var.project_prefix}-edge-cluster"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_compute_policy,
    aws_iam_role_policy_attachment.eks_block_storage_policy,
    aws_iam_role_policy_attachment.eks_load_balancing_policy,
    aws_iam_role_policy_attachment.eks_networking_policy,
  ]
}

# VPC Lattice prefix list — allow ingress on service ports
resource "aws_vpc_security_group_ingress_rule" "edge_lattice_ingress" {
  security_group_id = aws_eks_cluster.edge.vpc_config[0].cluster_security_group_id
  description       = "Allow VPC Lattice traffic"
  ip_protocol       = "-1"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.vpc_lattice.id
}

resource "aws_eks_access_entry" "edge_admin" {
  cluster_name  = aws_eks_cluster.edge.name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "edge_admin" {
  cluster_name  = aws_eks_cluster.edge.name
  principal_arn = aws_eks_access_entry.edge_admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# =============================================================================
# Gateway API Controller Pod Identity Association (edge cluster)
# =============================================================================

resource "aws_eks_pod_identity_association" "edge_gateway_api_controller" {
  cluster_name    = aws_eks_cluster.edge.name
  namespace       = "aws-application-networking-system"
  service_account = "gateway-api-controller"
  role_arn        = aws_iam_role.gateway_api_controller.arn
}

# =============================================================================
# WAF WebACL — standard protections for the internet-facing ALB
# =============================================================================

resource "aws_wafv2_web_acl" "frontend" {
  name  = "${var.project_prefix}-frontend-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Managed Rules — Core Rule Set (XSS, SQLi, etc.)
  rule {
    name     = "aws-managed-crs"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_prefix}-crs"
    }
  }

  # AWS Managed Rules — Known Bad Inputs (Log4j, request smuggling, etc.)
  rule {
    name     = "aws-managed-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_prefix}-bad-inputs"
    }
  }

  # Rate limiting (per IP)
  rule {
    name     = "rate-limit"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 10000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_prefix}-rate-limit"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_prefix}-waf"
  }

  tags = {
    Name = "${var.project_prefix}-frontend-waf"
  }
}
