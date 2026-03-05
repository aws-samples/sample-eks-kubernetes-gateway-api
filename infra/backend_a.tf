# # =============================================================================
# # Backend A — VPC, EKS Cluster (Auto Mode), Gateway API Controller
# # Hosts: cart service + inventory service
# # =============================================================================

# # =============================================================================
# # Backend A VPC
# # =============================================================================

resource "aws_ecr_repository" "cart_service" {
  name                 = "${var.project_prefix}/cart-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "inventory_service" {
  name                 = "${var.project_prefix}/inventory-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

module "backend_a_vpc" {
  source  = "aws-ia/vpc/aws"
  version = "= 4.7.3"

  name                                 = "${var.project_prefix}-backend-a-vpc"
  cidr_block                           = "10.0.0.0/16"
  vpc_assign_generated_ipv6_cidr_block = true
  vpc_egress_only_internet_gateway     = true
  az_count                             = 2

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
# CloudWatch log groups (for VPC Lattice service logs)
# =============================================================================

resource "aws_cloudwatch_log_group" "items_service_loggroup" {
  name              = "/aws/vpc-lattice/${var.project_prefix}-items-service"
  retention_in_days = 7
}

# =============================================================================
# EKS Backend A Cluster (Auto Mode)
# =============================================================================

resource "aws_eks_cluster" "backend_a" {
  name     = "${var.project_prefix}-backend-a-cluster"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.35"

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
    subnet_ids              = [for k, v in module.backend_a_vpc.private_subnet_attributes_by_az : v.id if startswith(k, "private/")]
  }

  tags = {
    Name = "${var.project_prefix}-backend-a-cluster"
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
resource "aws_vpc_security_group_ingress_rule" "backend_a_lattice_ingress" {
  security_group_id = aws_eks_cluster.backend_a.vpc_config[0].cluster_security_group_id
  description       = "Allow VPC Lattice traffic"
  ip_protocol       = "-1"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.vpc_lattice.id
}

# EKS Access Entry for cluster admin
resource "aws_eks_access_entry" "backend_a_admin" {
  cluster_name  = aws_eks_cluster.backend_a.name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "backend_a_admin" {
  cluster_name  = aws_eks_cluster.backend_a.name
  principal_arn = aws_eks_access_entry.backend_a_admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# =============================================================================
# Gateway API Controller Pod Identity Association (backend-a cluster)
# =============================================================================

resource "aws_eks_pod_identity_association" "backend_a_gateway_api_controller" {
  cluster_name    = aws_eks_cluster.backend_a.name
  namespace       = "aws-application-networking-system"
  service_account = "gateway-api-controller"
  role_arn        = aws_iam_role.gateway_api_controller.arn
}
