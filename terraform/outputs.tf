# =============================================================================
# outputs.tf — Root Outputs
# =============================================================================

# ── Network Outputs ───────────────────────────────────────────────────────────
output "dr_vpc_id" {
  description = "DR VPC ID"
  value       = module.network.vpc_id
}

output "dr_public_subnet_ids" {
  description = "DR public subnet IDs"
  value       = module.network.public_subnet_ids
}

output "dr_app_subnet_ids" {
  description = "DR private app subnet IDs"
  value       = module.network.app_subnet_ids
}

output "dr_db_subnet_ids" {
  description = "DR private DB subnet IDs"
  value       = module.network.db_subnet_ids
}

output "security_group_ids" {
  description = "All DR security group IDs"
  value = {
    nginx  = module.network.sg_nginx_id
    app    = module.network.sg_app_id
    aurora = module.network.sg_aurora_id
    lambda = module.network.sg_lambda_id
    alb    = module.network.sg_alb_id
  }
}

# ── Database Outputs ──────────────────────────────────────────────────────────
output "dr_aurora_cluster_id" {
  description = "DR Aurora cluster identifier"
  value       = module.database.dr_cluster_id
}

output "dr_aurora_reader_endpoint" {
  description = "DR Aurora reader endpoint (use as DB connection string before failover)"
  value       = module.database.dr_cluster_reader_endpoint
}

output "dr_aurora_cluster_endpoint" {
  description = "DR Aurora writer endpoint (available after failover promotion)"
  value       = module.database.dr_cluster_endpoint
}

output "dr_kms_key_arn" {
  description = "KMS key ARN used for DR Aurora encryption"
  value       = module.database.kms_key_arn
}

# ── Compute Outputs ───────────────────────────────────────────────────────────
output "app_launch_template_id" {
  description = "EC2 Launch Template ID for app servers"
  value       = module.compute.app_launch_template_id
}

output "nginx_launch_template_id" {
  description = "EC2 Launch Template ID for Nginx proxy"
  value       = module.compute.nginx_launch_template_id
}

output "nginx_eip_allocation_id" {
  description = "Elastic IP allocation ID for Nginx (use in failover script)"
  value       = module.compute.nginx_eip_allocation_id
}

output "s3_crr_role_arn" {
  description = "IAM role ARN for S3 Cross-Region Replication"
  value       = module.compute.s3_crr_role_arn
}

output "dr_sqs_queue_urls" {
  description = "DR SQS queue URLs"
  value       = module.compute.sqs_queue_urls
}

# ── Summary ───────────────────────────────────────────────────────────────────
output "dr_summary" {
  description = "DR infrastructure summary"
  value = {
    primary_region     = var.primary_region
    dr_region          = var.dr_region
    rto_target         = "25-35 minutes"
    rpo_target         = "< 1 minute"
    dr_strategy        = "Warm Standby"
    aurora_cluster     = module.database.dr_cluster_id
    db_reader_endpoint = module.database.dr_cluster_reader_endpoint
    next_step          = "Run failover-execute.sh only during a declared DR event"
  }
}
