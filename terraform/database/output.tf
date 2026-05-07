# =============================================================================
# database/outputs.tf
# =============================================================================

output "dr_cluster_id" {
  description = "DR Aurora cluster identifier"
  value       = aws_rds_cluster.dr.cluster_identifier
}

output "dr_cluster_endpoint" {
  description = "DR Aurora cluster writer endpoint (active after failover)"
  value       = aws_rds_cluster.dr.endpoint
}

output "dr_cluster_reader_endpoint" {
  description = "DR Aurora cluster reader endpoint"
  value       = aws_rds_cluster.dr.reader_endpoint
}

output "kms_key_arn" {
  description = "KMS key ARN for DR Aurora encryption"
  value       = aws_kms_key.aurora_dr.arn
}

output "kms_key_id" {
  description = "KMS key ID for DR Aurora encryption"
  value       = aws_kms_key.aurora_dr.key_id
}
