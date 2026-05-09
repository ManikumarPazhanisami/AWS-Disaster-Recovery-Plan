output "secret_arn_primary" {
  description = "ARN of the secret in the primary region"
  value       = aws_secretsmanager_secret.app_secret.arn
}

output "secret_replica_arn" {
  description = "ARN of the secret replica in the DR region"
  value       = aws_secretsmanager_secret.app_secret.replica[0].status
}

output "kms_key_arn_primary" {
  value = aws_kms_key.secrets_primary.arn
}

output "kms_key_arn_dr" {
  value = aws_kms_key.secrets_dr.arn
}
