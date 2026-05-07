# =============================================================================
# variables.tf — Root Variables
# AWS Disaster Recovery Plan — US-East-1 (Primary) → US-West-1 (DR)
# =============================================================================

variable "primary_region" {
  description = "AWS Primary Region"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "AWS DR Region"
  type        = string
  default     = "us-west-1"
}

variable "project_name" {
  description = "Project name used for tagging and naming resources"
  type        = string
  default     = "ias-prod"
}

variable "environment" {
  description = "Environment tag for DR resources"
  type        = string
  default     = "DR"
}

# ── Network ───────────────────────────────────────────────────────────────────
variable "dr_vpc_cidr" {
  description = "CIDR block for the DR VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "primary_vpc_cidr" {
  description = "CIDR block of the primary VPC (us-east-1) for security group rules"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "app_subnet_cidrs" {
  description = "CIDR blocks for private app subnets (one per AZ)"
  type        = list(string)
  default     = ["10.1.10.0/24", "10.1.11.0/24"]
}

variable "db_subnet_cidrs" {
  description = "CIDR blocks for private DB subnets (one per AZ)"
  type        = list(string)
  default     = ["10.1.20.0/24", "10.1.21.0/24"]
}

variable "availability_zones" {
  description = "Availability zones in us-west-1"
  type        = list(string)
  default     = ["us-west-1a", "us-west-1b"]
}

# ── Database ──────────────────────────────────────────────────────────────────
variable "primary_cluster_identifier" {
  description = "Aurora cluster identifier in the primary region"
  type        = string
  default     = "ias-prod-cluster"
}

variable "dr_cluster_identifier" {
  description = "Aurora DR cluster identifier"
  type        = string
  default     = "ias-prod-cluster-dr"
}

variable "aurora_engine_version" {
  description = "Aurora MySQL engine version"
  type        = string
  default     = "8.0.mysql_aurora.3.08.2"
}

variable "aurora_min_capacity" {
  description = "Aurora Serverless v2 minimum ACU capacity"
  type        = number
  default     = 1
}

variable "aurora_max_capacity" {
  description = "Aurora Serverless v2 maximum ACU capacity"
  type        = number
  default     = 8
}

variable "db_master_username" {
  description = "Master username for Aurora (used only during promotion)"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "db_master_password" {
  description = "Master password for Aurora (used only during promotion)"
  type        = string
  sensitive   = true
  default     = ""  # Override via TF_VAR_db_master_password or tfvars
}

# ── Compute ───────────────────────────────────────────────────────────────────
variable "app_instance_type" {
  description = "EC2 instance type for Node.js app servers"
  type        = string
  default     = "t3.medium"
}

variable "nginx_instance_type" {
  description = "EC2 instance type for Nginx proxy"
  type        = string
  default     = "t3.small"
}

variable "app_instance_count" {
  description = "Number of app EC2 instances to launch in DR"
  type        = number
  default     = 2
}

variable "app_ami_id" {
  description = "AMI ID for the Node.js app server (copied from us-east-1)"
  type        = string
  default     = ""  # Set after running: aws ec2 copy-image
}

variable "nginx_ami_id" {
  description = "AMI ID for the Nginx proxy (copied from us-east-1)"
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
  default     = "dr-key-pair"
}

# ── S3 ────────────────────────────────────────────────────────────────────────
variable "s3_bucket_names" {
  description = "List of S3 bucket base names to replicate (without region suffix)"
  type        = list(string)
  default     = ["mybucket-prod"]
}

# ── Route53 ──────────────────────────────────────────────────────────────────
variable "hosted_zone_id" {
  description = "Route53 Hosted Zone ID"
  type        = string
  default     = ""  # e.g. ZXXXXXXXXXXXXX
}

variable "api_domain" {
  description = "Application-facing domain name"
  type        = string
  default     = "api.yourdomain.com"
}

variable "db_cname" {
  description = "CNAME used by app to connect to DB"
  type        = string
  default     = "db.yourdomain.com"
}

# ── Monitoring ────────────────────────────────────────────────────────────────
variable "sns_alarm_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications"
  type        = string
  default     = ""
}

variable "replication_lag_threshold_ms" {
  description = "CloudWatch alarm threshold for Aurora replication lag (ms)"
  type        = number
  default     = 5000
}
