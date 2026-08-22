################################################################################
# PROD Environment — Medical B2B ERP
# Key differences from dev:
#   - ON_DEMAND nodes (no Spot)
#   - Private EKS endpoint only
#   - More replicas
#   - Larger instance types
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "med-erp-terraform-state-prod"
    key            = "prod/terraform.tfstate"
    region         = "eu-north-1"
    encrypt        = true
    dynamodb_table = "med-erp-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

locals {
  environment  = "prod"
  project      = "med-erp"
  cluster_name = "${local.project}-${local.environment}-eks"

  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "Terraform"
    Owner       = "DevOps"
  }
}

module "vpc" {
  source       = "../../modules/vpc"
  name         = "${local.project}-${local.environment}"
  vpc_cidr     = "10.20.0.0/16"
  cluster_name = local.cluster_name
  tags         = local.common_tags
}

module "eks" {
  source              = "../../modules/eks"
  cluster_name        = local.cluster_name
  kubernetes_version  = "1.35"
  vpc_id              = module.vpc.vpc_id
  vpc_cidr            = module.vpc.vpc_cidr
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_types = ["m5.xlarge"]
  capacity_type       = "ON_DEMAND"
  node_desired_count  = 3
  node_min_count      = 2
  node_max_count      = 10
  public_endpoint     = false    # Private endpoint only
  tags                = local.common_tags
}

module "ecr" {
  source  = "../../modules/ecr"
  project = local.project
  tags    = local.common_tags
}

module "frontend" {
  source              = "../../modules/s3-cloudfront"
  project             = local.project
  environment         = local.environment
  domain_names        = ["med-erp.${var.domain_name}", "www.med-erp.${var.domain_name}"]
  acm_certificate_arn = var.acm_certificate_arn
  tags                = local.common_tags
}

module "dns" {
  source                 = "../../modules/route53"
  domain_name            = var.domain_name
  frontend_subdomain     = "med-erp"
  api_subdomain          = "api.med-erp"
  cloudfront_domain_name = module.frontend.cloudfront_domain_name
  alb_dns_name           = var.alb_dns_name
  tags                   = local.common_tags
}
