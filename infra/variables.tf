# =============================================================================
# Variable Definitions
# =============================================================================

# -----------------------------------------------------------------------------
# Required Variables
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for deployment. Must support VPC Lattice and EKS."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate ARN for VPC Lattice service HTTPS listeners. Must be in the deployment region."
  type        = string
}

variable "private_hosted_zone_name" {
  description = "Domain name for the Route 53 private hosted zone. Used for internal service discovery via VPC Lattice."
  type        = string
}

variable "public_hosted_zone_id" {
  description = "Route 53 public hosted zone ID. Used by ExternalDNS to create ALIAS records for the ALB."
  type        = string
}

variable "frontend_domain_name" {
  description = "Custom domain name for the frontend ALB (e.g. frontend.example.com). ExternalDNS creates the Route 53 record."
  type        = string
}

# -----------------------------------------------------------------------------
# Optional Variables
# -----------------------------------------------------------------------------

variable "project_prefix" {
  description = "Project name prefix for all resource names."
  type        = string
  default     = "eks-gateway-demo"
}
