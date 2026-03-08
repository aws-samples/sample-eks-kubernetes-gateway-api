# =============================================================================
# Terraform Outputs
# =============================================================================

output "frontend_waf_acl_arn" {
  description = "WAF WebACL ARN for the frontend ALB"
  value       = aws_wafv2_web_acl.frontend.arn
}

output "vpc_lattice_service_network_name" {
  description = "VPC Lattice service network name"
  value       = module.vpclattice_service_network.service_network.name
}

output "private_hosted_zone_id" {
  description = "Route 53 private hosted zone ID"
  value       = aws_route53_zone.private_hz.zone_id
}

output "edge_vpc_id" {
  description = "Edge VPC ID"
  value       = module.edge_vpc.vpc_attributes.id
}

output "backend_a_vpc_id" {
  description = "Backend A VPC ID"
  value       = module.backend_a_vpc.vpc_attributes.id
}

output "backend_b_vpc_id" {
  description = "Backend B VPC ID"
  value       = module.backend_b_vpc.vpc_attributes.id
}

output "items_service_log_group_arn" {
  description = "CloudWatch log group ARN for Items (catalog+pricing) VPC Lattice access logs"
  value       = aws_cloudwatch_log_group.items_service_loggroup.arn
}

output "payments_service_log_group_arn" {
  description = "CloudWatch log group ARN for Payments Service VPC Lattice access logs"
  value       = aws_cloudwatch_log_group.payments_service_loggroup.arn
}

output "cart_service_log_group_arn" {
  description = "CloudWatch log group ARN for Cart Service VPC Lattice access logs"
  value       = aws_cloudwatch_log_group.cart_service_loggroup.arn
}

output "edge_cluster_name" {
  description = "Edge EKS cluster name"
  value       = aws_eks_cluster.edge.name
}

output "backend_a_cluster_name" {
  description = "Backend A EKS cluster name"
  value       = aws_eks_cluster.backend_a.name
}

output "backend_b_cluster_name" {
  description = "Backend B EKS cluster name"
  value       = aws_eks_cluster.backend_b.name
}