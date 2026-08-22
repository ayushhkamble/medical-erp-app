################################################################################
# DEV Environment — Medical B2B ERP
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

  # Remote state — use S3 backend
  backend "s3" {
    bucket         = "med-erp-terraform-state-dev"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
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
  environment  = "dev"
  project      = "med-erp"
  cluster_name = "${local.project}-${local.environment}-eks"

  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "Terraform"
    Owner       = "DevOps"
  }
}

# ── VPC ────────────────────────────────────────────────────────────────────────
module "vpc" {
  source       = "../../modules/vpc"
  name         = "${local.project}-${local.environment}"
  vpc_cidr     = "10.10.0.0/16"
  cluster_name = local.cluster_name
  tags         = local.common_tags
}

# ── EKS ────────────────────────────────────────────────────────────────────────
module "eks" {
  source                = "../../modules/eks"
  cluster_name          = local.cluster_name
  kubernetes_version    = "1.30"
  vpc_id                = module.vpc.vpc_id
  vpc_cidr              = module.vpc.vpc_cidr
  private_subnet_ids    = module.vpc.private_subnet_ids
  node_instance_types   = ["c7i-flex.large"]
  capacity_type         = "SPOT"       # Use Spot for dev cost savings
  node_desired_count    = 2
  node_min_count        = 1
  node_max_count        = 4
  public_endpoint       = true         # Allow kubectl from dev machines
  public_access_cidrs   = [var.developer_ip_cidr]
  tags                  = local.common_tags
}

# ── ECR ────────────────────────────────────────────────────────────────────────
module "ecr" {
  source  = "../../modules/ecr"
    repositories = [
    "med-erp/order",
    "med-erp/product",
    "med-erp/user"
  ]
  project = local.project
  tags    = local.common_tags
}

# ── S3 + CloudFront ────────────────────────────────────────────────────────────
module "frontend" {
  source              = "../../modules/s3-cloudfront"
  project             = local.project
  environment         = local.environment
  domain_names        = ["dev.med-erp.${var.domain_name}"]
  acm_certificate_arn = var.acm_certificate_arn
  tags                = local.common_tags
}

# ── Route53 ────────────────────────────────────────────────────────────────────
module "dns" {
  source                 = "../../modules/route53"
  domain_name            = var.domain_name
  frontend_subdomain     = "dev.med-erp"
  api_subdomain          = "dev.api.med-erp"
  cloudfront_domain_name = module.frontend.cloudfront_domain_name
  alb_dns_name           = var.alb_dns_name   # Set after ALB Ingress Controller deploys
  tags                   = local.common_tags
}
