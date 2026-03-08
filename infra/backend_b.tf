# # =============================================================================
# # Backend B — VPC, EKS Cluster (Auto Mode), Gateway API Controller
# # Hosts: cart service (also consumes Payments via VPC Lattice)
# # =============================================================================

# # =============================================================================
# # Backend B VPC
# # =============================================================================

resource "aws_ecr_repository" "cart" {
  #checkov:skip=CKV_AWS_136:KMS encryption adds cost and complexity not relevant to this Gateway API sample
  #checkov:skip=CKV_AWS_51:Mutable tags accepted for this sample — see security/report.html
  name                 = "${var.project_prefix}/cart"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

module "backend_b_vpc" {
  #checkov:skip=CKV_TF_1:Version pinning is sufficient for a sample; commit hash pinning is a production concern
  source  = "aws-ia/vpc/aws"
  version = "= 4.7.3"

  name                                 = "${var.project_prefix}-backend-b-vpc"
  cidr_block                           = "10.0.0.0/16"
  vpc_assign_generated_ipv6_cidr_block = true
  vpc_egress_only_internet_gateway     = true
  az_count                             = 2

  vpc_lattice = {
    service_network_identifier = module.vpclattice_service_network.service_network.id
  }

  subnets = {
    public = {
      netmask                   = 24
      assign_ipv6_cidr          = true
      nat_gateway_configuration = "all_azs"
    }
    private = {
      netmask                 = 24
      connect_to_public_natgw = true
      assign_ipv6_cidr        = true
      connect_to_eigw         = true
    }
  }
}

# =============================================================================
# CloudWatch log group (for VPC Lattice service logs)
# =============================================================================

resource "aws_cloudwatch_log_group" "cart_service_loggroup" {
  #checkov:skip=CKV_AWS_158:KMS encryption adds cost and complexity not relevant to this Gateway API sample
  #checkov:skip=CKV_AWS_338:7-day retention is sufficient for a sample; increase for production
  name              = "/aws/vpc-lattice/${var.project_prefix}-cart-service"
  retention_in_days = 7
}

# =============================================================================
# EKS Backend B Cluster (Auto Mode)
# =============================================================================

resource "aws_eks_cluster" "backend_b" {
  name     = "${var.project_prefix}-backend-b-cluster"
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
    subnet_ids              = [for k, v in module.backend_b_vpc.private_subnet_attributes_by_az : v.id if startswith(k, "private/")]
  }

  tags = {
    Name = "${var.project_prefix}-backend-b-cluster"
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
resource "aws_vpc_security_group_ingress_rule" "backend_b_lattice_ingress" {
  security_group_id = aws_eks_cluster.backend_b.vpc_config[0].cluster_security_group_id
  description       = "Allow VPC Lattice traffic"
  ip_protocol       = "-1"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.vpc_lattice.id
}

# EKS Access Entry for cluster admin
resource "aws_eks_access_entry" "backend_b_admin" {
  cluster_name  = aws_eks_cluster.backend_b.name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "backend_b_admin" {
  cluster_name  = aws_eks_cluster.backend_b.name
  principal_arn = aws_eks_access_entry.backend_b_admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# =============================================================================
# Gateway API Controller Pod Identity Association (backend-b cluster)
# =============================================================================

resource "aws_eks_pod_identity_association" "backend_b_gateway_api_controller" {
  cluster_name    = aws_eks_cluster.backend_b.name
  namespace       = "aws-application-networking-system"
  service_account = "gateway-api-controller"
  role_arn        = aws_iam_role.gateway_api_controller.arn
}

# =============================================================================
# Cart Pod Identity — allows cart service to call Payments via VPC Lattice
# =============================================================================

resource "aws_eks_pod_identity_association" "cart_pod" {
  cluster_name    = aws_eks_cluster.backend_b.name
  namespace       = "default"
  service_account = "cart-service-account"
  role_arn        = aws_iam_role.cart_pod.arn
}
