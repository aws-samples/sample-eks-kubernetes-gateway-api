# =============================================================================
# Terraform Provider Configuration
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}

# Default AWS provider
provider "aws" {
  region = var.aws_region
}
