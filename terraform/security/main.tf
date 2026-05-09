terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws.primary, aws.dr]
    }
  }
}

# ── KMS Key for Secret Encryption in Primary Region ──────────────────────────
resource "aws_kms_key" "secrets_primary" {
  provider                = aws.primary
  description             = "Secrets Manager encryption key - Primary"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name        = "kms-secrets-primary-${var.project_name}"
    Environment = var.environment
  }
}

resource "aws_kms_alias" "secrets_primary" {
  provider      = aws.primary
  name          = "alias/secrets-primary-${var.project_name}"
  target_key_id = aws_kms_key.secrets_primary.key_id
}

# ── KMS Key for Secret Encryption in DR Region ───────────────────────────────
resource "aws_kms_key" "secrets_dr" {
  provider                = aws.dr
  description             = "Secrets Manager encryption key - DR"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name        = "kms-secrets-dr-${var.project_name}"
    Environment = var.environment
  }
}

resource "aws_kms_alias" "secrets_dr" {
  provider      = aws.dr
  name          = "alias/secrets-dr-${var.project_name}"
  target_key_id = aws_kms_key.secrets_dr.key_id
}

# ── Secrets Manager Secret with Cross-Region Replication ──────────────────────
resource "aws_secretsmanager_secret" "app_secret" {
  provider                = aws.primary
  name                    = "${var.secret_name}-${var.project_name}"
  description             = "Application credentials with DR replication"
  kms_key_id              = aws_kms_key.secrets_primary.arn
  recovery_window_in_days = 30

  replica {
    region     = var.dr_region
    kms_key_id = aws_kms_key.secrets_dr.arn
  }

  tags = {
    Name        = "${var.secret_name}-${var.project_name}"
    Environment = var.environment
  }
}
