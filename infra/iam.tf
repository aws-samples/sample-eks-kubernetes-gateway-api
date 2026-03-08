# =============================================================================
# IAM Roles, Policies, and Pod Identity Associations
# =============================================================================
#
# This file contains all IAM resources used across the project:
#
# TRUST POLICIES (shared data sources):
#   - eks_assume_role          → Used by: EKS cluster role
#   - ec2_assume_role          → Used by: EKS Auto Mode node role
#   - pod_identity_assume_role → Used by: All Pod Identity roles (AWS LBC, BFF, VPC Lattice controller)
#
# ROLES:
#   ┌─────────────────────────────┬──────────────────────────────────────────────────────────┐
#   │ Role                        │ Purpose                                                  │
#   ├─────────────────────────────┼──────────────────────────────────────────────────────────┤
#   │ eks_cluster                 │ EKS control plane (shared by all 3 clusters)             │
#   │ eks_node_group              │ EKS Auto Mode worker nodes (shared by all 3 clusters)    │
#   │ gateway_api_controller      │ VPC Lattice Gateway API Controller (edge + backends)     │
#   │ aws_lbc                     │ AWS Load Balancer Controller (edge cluster)              │
#   │ bff_pod                     │ BFF service — SigV4 signing for VPC Lattice (edge)       │
#   │ external_dns                │ ExternalDNS — Route 53 record management (all clusters)  │
#   └─────────────────────────────┴──────────────────────────────────────────────────────────┘
#
# =============================================================================

# =============================================================================
# Shared trust policies
# =============================================================================

data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "pod_identity_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# =============================================================================
# EKS Cluster Role — shared by all 3 clusters (Auto Mode control plane)
# Grants EKS permissions to manage compute, networking, storage, and LB.
# =============================================================================

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project_prefix}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role.json
  tags               = { Name = "${var.project_prefix}-eks-cluster-role" }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_compute_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSComputePolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_block_storage_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_load_balancing_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_networking_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# =============================================================================
# EKS Node Role — shared by all 3 clusters (Auto Mode worker nodes)
# Minimal permissions for EC2 instances to join the cluster and pull images.
# =============================================================================

resource "aws_iam_role" "eks_node_group" {
  name               = "${var.project_prefix}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = { Name = "${var.project_prefix}-eks-node-role" }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_minimal_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_pull_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.eks_node_group.name
}

# =============================================================================
# VPC Lattice Gateway API Controller Role — edge and backend clusters
# Allows the controller to manage VPC Lattice services, target groups, and
# service network associations via the Gateway API CRDs.
# =============================================================================

resource "aws_iam_role" "gateway_api_controller" {
  name               = "${var.project_prefix}-gateway-api-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  tags               = { Name = "${var.project_prefix}-gateway-api-controller-role" }
}

data "aws_iam_policy_document" "gateway_api_controller" {
  statement {
    effect = "Allow"
    actions = [
      "vpc-lattice:*",
      "ec2:DescribeVpcs",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeSecurityGroups",
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:DescribeLogGroups",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "tag:GetResources",
      "tag:TagResources",
      "tag:UntagResources",
      "firehose:TagDeliveryStream",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::*:role/aws-service-role/vpc-lattice.amazonaws.com/AWSServiceRoleForVpcLattice"]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values   = ["vpc-lattice.amazonaws.com"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::*:role/aws-service-role/delivery.logs.amazonaws.com/AWSServiceRoleForLogDelivery"]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values   = ["delivery.logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "gateway_api_controller" {
  #checkov:skip=CKV_AWS_109:VPC Lattice controller requires broad permissions; resource ARNs are dynamic
  #checkov:skip=CKV_AWS_111:VPC Lattice controller requires broad permissions; resource ARNs are dynamic
  #checkov:skip=CKV_AWS_356:VPC Lattice controller requires broad permissions; resource ARNs are dynamic
  name   = "${var.project_prefix}-gateway-api-controller-policy"
  role   = aws_iam_role.gateway_api_controller.id
  policy = data.aws_iam_policy_document.gateway_api_controller.json
}

# =============================================================================
# AWS Load Balancer Controller Role — edge cluster only
# Allows the self-managed AWS LBC (installed via Helm with Gateway API feature
# gates) to provision and manage ALBs/NLBs. Not part of EKS Auto Mode.
# Reference: https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.1.0/docs/install/iam_policy.json
# =============================================================================

resource "aws_iam_role" "aws_lbc" {
  name               = "${var.project_prefix}-aws-lbc-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  tags               = { Name = "${var.project_prefix}-aws-lbc-role" }
}

data "aws_iam_policy_document" "aws_lbc" {
  statement {
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "ec2:GetSecurityGroupsForVpc",
      "ec2:DescribeIpamPools",
      "ec2:DescribeRouteTables",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeTrustStores",
      "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:DescribeCapacityReservation",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "cognito-idp:DescribeUserPoolClient",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "iam:ListServerCertificates",
      "iam:GetServerCertificate",
      "waf-regional:GetWebACL",
      "waf-regional:GetWebACLForResource",
      "waf-regional:AssociateWebACL",
      "waf-regional:DisassociateWebACL",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
      "shield:GetSubscriptionState",
      "shield:DescribeProtection",
      "shield:CreateProtection",
      "shield:DeleteProtection",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:*:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
    resources = ["arn:aws:ec2:*:*:security-group/*"]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress", "ec2:DeleteSecurityGroup"]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup"]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
    ]
    resources = ["*"]
  }

  statement {
    effect  = "Allow"
    actions = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect  = "Allow"
    actions = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyListenerAttributes",
      "elasticloadbalancing:ModifyCapacityReservation",
      "elasticloadbalancing:ModifyIpPools",
    ]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect  = "Allow"
    actions = ["elasticloadbalancing:AddTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "elasticloadbalancing:CreateAction"
      values   = ["CreateTargetGroup", "CreateLoadBalancer"]
    }
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
    resources = ["arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:SetWebAcl",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:SetRulePriorities",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "aws_lbc" {
  #checkov:skip=CKV_AWS_109:AWS LBC requires broad permissions; load balancer ARNs are dynamic
  #checkov:skip=CKV_AWS_111:AWS LBC requires broad permissions; load balancer ARNs are dynamic
  #checkov:skip=CKV_AWS_356:AWS LBC requires broad permissions; load balancer ARNs are dynamic
  name   = "${var.project_prefix}-aws-lbc-policy"
  role   = aws_iam_role.aws_lbc.id
  policy = data.aws_iam_policy_document.aws_lbc.json
}

resource "aws_eks_pod_identity_association" "aws_lbc" {
  cluster_name    = aws_eks_cluster.edge.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_lbc.arn
}

# =============================================================================
# BFF Pod Role — edge cluster only
# Allows the BFF service to sign requests with SigV4 for VPC Lattice IAM auth.
# =============================================================================

resource "aws_iam_role" "bff_pod" {
  name               = "${var.project_prefix}-bff-pod-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  tags               = { Name = "${var.project_prefix}-bff-pod-role" }
}

data "aws_iam_policy_document" "bff_lattice_invoke" {
  statement {
    effect    = "Allow"
    actions   = ["vpc-lattice-svcs:Invoke"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bff_lattice_invoke" {
  name   = "${var.project_prefix}-bff-lattice-invoke"
  role   = aws_iam_role.bff_pod.id
  policy = data.aws_iam_policy_document.bff_lattice_invoke.json
}

resource "aws_eks_pod_identity_association" "bff" {
  cluster_name    = aws_eks_cluster.edge.name
  namespace       = "default"
  service_account = "bff-service-account"
  role_arn        = aws_iam_role.bff_pod.arn
}

# =============================================================================
# ExternalDNS Role — all clusters
# Watches Gateway/HTTPRoute resources and creates Route 53 records.
# Edge cluster: ALIAS records in the public hosted zone (ALB)
# Backend clusters: CNAME records in the private hosted zone (VPC Lattice)
# =============================================================================

resource "aws_iam_role" "external_dns" {
  name               = "${var.project_prefix}-external-dns-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  tags               = { Name = "${var.project_prefix}-external-dns-role" }
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    effect  = "Allow"
    actions = ["route53:ChangeResourceRecordSets"]
    resources = [
      "arn:aws:route53:::hostedzone/${var.public_hosted_zone_id}",
      aws_route53_zone.private_hz.arn,
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "${var.project_prefix}-external-dns-policy"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

# Pod Identity — one per cluster
resource "aws_eks_pod_identity_association" "external_dns_edge" {
  cluster_name    = aws_eks_cluster.edge.name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}

resource "aws_eks_pod_identity_association" "external_dns_backend_a" {
  cluster_name    = aws_eks_cluster.backend_a.name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}

resource "aws_eks_pod_identity_association" "external_dns_backend_b" {
  cluster_name    = aws_eks_cluster.backend_b.name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}

# =============================================================================
# Cart Pod Role — Backend-B cluster
# Allows the cart service to call Payments via VPC Lattice with SigV4 signing.
# =============================================================================

resource "aws_iam_role" "cart_pod" {
  name               = "${var.project_prefix}-cart-pod-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  tags               = { Name = "${var.project_prefix}-cart-pod-role" }
}

resource "aws_iam_role_policy" "cart_lattice_invoke" {
  name   = "${var.project_prefix}-cart-lattice-invoke"
  role   = aws_iam_role.cart_pod.id
  policy = data.aws_iam_policy_document.bff_lattice_invoke.json
}
