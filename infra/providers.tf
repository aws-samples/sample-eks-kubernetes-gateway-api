# =============================================================================
# Terraform Provider Configuration
# =============================================================================

terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }

  # Uncomment and configure for team use — local state is fine for individual evaluation.
  # backend "s3" {
  #   bucket         = "<your-state-bucket>"
  #   key            = "eks-gateway-demo/terraform.tfstate"
  #   region         = "<your-region>"
  # }
}

# Default AWS provider
provider "aws" {
  region = var.aws_region
}
