# =============================================================================
# main.tf — Root Module
# AWS Disaster Recovery Plan — US-East-1 (Primary) → US-West-1 (DR)
#
# Usage:
#   terraform init
#   terraform plan -var-file="terraform.tfvars"
#   terraform apply -var-file="terraform.tfvars"
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Recommended: use S3 backend for team collaboration
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "dr-plan/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

# ── Providers ─────────────────────────────────────────────────────────────────
provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "Terraform"
      Repository  = "AWS-Disaster-Recovery-Plan"
    }
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "AWS-Disaster-Recovery-Plan"
    }
  }
}

# ── Security Module ───────────────────────────────────────────────────────────
module "security" {
  source = "./security"

  providers = {
    aws.primary = aws.primary
    aws.dr      = aws.dr
  }

  project_name = var.project_name
  environment  = var.environment
  dr_region    = var.dr_region
}

# ── Network Module ────────────────────────────────────────────────────────────
module "network" {
  source = "./network"

  providers = {
    aws = aws.dr
  }

  project_name        = var.project_name
  environment         = var.environment
  vpc_cidr            = var.dr_vpc_cidr
  primary_vpc_cidr    = var.primary_vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  db_subnet_cidrs     = var.db_subnet_cidrs
  availability_zones  = var.availability_zones
}

# ── Database Module ───────────────────────────────────────────────────────────
module "database" {
  source = "./database"

  providers = {
    aws.primary = aws.primary
    aws.dr      = aws.dr
  }

  project_name               = var.project_name
  environment                = var.environment
  dr_region                  = var.dr_region
  primary_cluster_identifier = var.primary_cluster_identifier
  dr_cluster_identifier      = var.dr_cluster_identifier
  aurora_engine_version      = var.aurora_engine_version
  aurora_min_capacity        = var.aurora_min_capacity
  aurora_max_capacity        = var.aurora_max_capacity
  db_subnet_group_name       = module.network.db_subnet_group_name
  aurora_security_group_id   = module.network.sg_aurora_id
  sns_alarm_arn              = var.sns_alarm_arn
  replication_lag_threshold  = var.replication_lag_threshold_ms

  depends_on = [module.network]
}

# ── Compute Module ────────────────────────────────────────────────────────────
module "compute" {
  source = "./compute"

  providers = {
    aws = aws.dr
  }

  project_name         = var.project_name
  environment          = var.environment
  primary_region       = var.primary_region
  dr_region            = var.dr_region
  app_subnet_ids       = module.network.app_subnet_ids
  public_subnet_ids    = module.network.public_subnet_ids
  sg_app_id            = module.network.sg_app_id
  sg_nginx_id          = module.network.sg_nginx_id
  sg_lambda_id         = module.network.sg_lambda_id
  app_instance_type    = var.app_instance_type
  nginx_instance_type  = var.nginx_instance_type
  app_instance_count   = var.app_instance_count
  app_ami_id           = var.app_ami_id
  nginx_ami_id         = var.nginx_ami_id
  key_pair_name        = var.key_pair_name
  s3_bucket_names      = var.s3_bucket_names
  hosted_zone_id       = var.hosted_zone_id
  api_domain           = var.api_domain
  db_cname             = var.db_cname
  dr_db_endpoint       = module.database.dr_cluster_reader_endpoint
  sns_alarm_arn        = var.sns_alarm_arn
  secret_arn           = module.security.secret_arn_primary
  kms_key_arn          = module.security.kms_key_arn_dr

  depends_on = [module.network, module.database, module.security]
}
