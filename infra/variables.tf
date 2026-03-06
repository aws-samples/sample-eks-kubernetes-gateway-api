# =============================================================================
# Variable Definitions
# =============================================================================

# -----------------------------------------------------------------------------
# Always required
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for deployment. Must support VPC Lattice and EKS."
  type        = string
}

variable "private_hosted_zone_name" {
  description = "Domain name for the Route 53 private hosted zone. Used for internal service discovery via VPC Lattice regardless of protocol."
  type        = string
}

# -----------------------------------------------------------------------------
# ALB Protocol
# -----------------------------------------------------------------------------

variable "alb_protocol" {
  description = "Protocol for the frontend ALB. Use HTTPS (recommended for production) or HTTP (for test environments only)."
  type        = string
  default     = "HTTPS"

  validation {
    condition     = contains(["HTTP", "HTTPS"], var.alb_protocol)
    error_message = "alb_protocol must be either HTTP or HTTPS."
  }
}

# -----------------------------------------------------------------------------
# VPC Lattice Protocol
# -----------------------------------------------------------------------------

variable "vpclattice_protocol" {
  description = "Protocol for VPC Lattice service listeners. Use HTTPS (recommended for production) or HTTP (for test environments only)."
  type        = string
  default     = "HTTPS"

  validation {
    condition     = contains(["HTTP", "HTTPS"], var.vpclattice_protocol)
    error_message = "vpclattice_protocol must be either HTTP or HTTPS."
  }
}

# -----------------------------------------------------------------------------
# Required when alb_protocol = "HTTPS"
# -----------------------------------------------------------------------------

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for the ALB HTTPS listener. Required when alb_protocol = HTTPS."
  type        = string
  default     = null
}

variable "public_hosted_zone_id" {
  description = "Route 53 public hosted zone ID. Used by ExternalDNS to create ALIAS records for the ALB. Required when alb_protocol = HTTPS."
  type        = string
  default     = null
}

variable "frontend_domain_name" {
  description = "Custom domain name for the frontend ALB (e.g. frontend.example.com). ExternalDNS creates the Route 53 record. Required when alb_protocol = HTTPS."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Required when vpclattice_protocol = "HTTPS"
# -----------------------------------------------------------------------------

variable "vpclattice_certificate_arn" {
  description = "ACM certificate ARN for VPC Lattice service HTTPS listeners. Required when vpclattice_protocol = HTTPS. Must be in the deployment region."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Optional
# -----------------------------------------------------------------------------

variable "project_prefix" {
  description = "Project name prefix for all resource names."
  type        = string
  default     = "eks-gateway-demo"
}

variable "kubernetes_version" {
  description = "Kubernetes version for all EKS clusters. Must support EKS Auto Mode and Pod Identity."
  type        = string
  default     = "1.35"
}

# -----------------------------------------------------------------------------
# Validation: HTTPS-required fields
# -----------------------------------------------------------------------------

locals {
  https_missing_cert   = var.alb_protocol == "HTTPS" && var.alb_certificate_arn == null
  https_missing_hz     = var.alb_protocol == "HTTPS" && var.public_hosted_zone_id == null
  https_missing_domain = var.alb_protocol == "HTTPS" && var.frontend_domain_name == null

  https_validation_error = (
    local.https_missing_cert || local.https_missing_hz || local.https_missing_domain
    ? "When alb_protocol = HTTPS, the following variables are required: alb_certificate_arn, public_hosted_zone_id, frontend_domain_name."
    : null
  )

  vpclattice_https_missing_cert = var.vpclattice_protocol == "HTTPS" && var.vpclattice_certificate_arn == null
}

resource "terraform_data" "https_validation" {
  lifecycle {
    precondition {
      condition     = local.https_validation_error == null
      error_message = "alb_protocol is set to HTTPS but one or more required variables are missing: alb_certificate_arn, public_hosted_zone_id, frontend_domain_name."
    }
  }
}

resource "terraform_data" "vpclattice_https_validation" {
  lifecycle {
    precondition {
      condition     = !local.vpclattice_https_missing_cert
      error_message = "vpclattice_protocol is set to HTTPS but vpclattice_certificate_arn is not provided."
    }
  }
}
