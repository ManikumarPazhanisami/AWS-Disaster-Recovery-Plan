# =============================================================================
# database/main.tf
# Phase 4: KMS Key, Aurora Serverless v2 Cross-Region Read Replica,
#          Serverless v2 Scaling, CloudWatch Alarms
# =============================================================================

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws.primary, aws.dr]
    }
  }
}

# ── Get Primary Cluster ARN ───────────────────────────────────────────────────
data "aws_rds_cluster" "primary" {
  provider           = aws.primary
  cluster_identifier = var.primary_cluster_identifier
}

# ── KMS Key for DR Aurora Encryption ─────────────────────────────────────────
resource "aws_kms_key" "aurora_dr" {
  provider                = aws.dr
  description             = "Aurora DR encryption key - ${var.dr_region}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name        = "kms-aurora-dr-${var.project_name}"
    Environment = var.environment
    Purpose     = "AuroraEncryption"
  }
}

resource "aws_kms_alias" "aurora_dr" {
  provider      = aws.dr
  name          = "alias/aurora-dr-${var.project_name}"
  target_key_id = aws_kms_key.aurora_dr.key_id
}

# ── Aurora DR Cluster (Cross-Region Read Replica) ─────────────────────────────
resource "aws_rds_cluster" "dr" {
  provider = aws.dr

  cluster_identifier              = var.dr_cluster_identifier
  engine                          = "aurora-mysql"
  engine_version                  = var.aurora_engine_version
  replication_source_identifier   = data.aws_rds_cluster.primary.arn

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.aurora_security_group_id]

  storage_encrypted = true
  kms_key_id        = aws_kms_key.aurora_dr.arn

  # Serverless v2 scaling configuration
  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_capacity
    max_capacity = var.aurora_max_capacity
  }

  enabled_cloudwatch_logs_exports = ["error", "slowquery", "audit"]

  # Skip final snapshot for DR replica (primary has backups)
  skip_final_snapshot = true

  # Lifecycle: prevent accidental destroy of DR cluster
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [replication_source_identifier]
  }

  tags = {
    Name        = var.dr_cluster_identifier
    Environment = var.environment
    Role        = "DR-Replica"
  }
}

# ── Aurora DR Instance (Serverless v2) ────────────────────────────────────────
resource "aws_rds_cluster_instance" "dr" {
  provider = aws.dr

  identifier         = "${var.dr_cluster_identifier}-instance-1"
  cluster_identifier = aws_rds_cluster.dr.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.dr.engine
  engine_version     = aws_rds_cluster.dr.engine_version

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_enhanced_monitoring.arn

  auto_minor_version_upgrade = false

  tags = {
    Name        = "${var.dr_cluster_identifier}-instance-1"
    Environment = var.environment
  }
}

# ── IAM Role for Enhanced Monitoring ─────────────────────────────────────────
resource "aws_iam_role" "rds_enhanced_monitoring" {
  provider = aws.dr
  name     = "rds-enhanced-monitoring-${var.project_name}-dr"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  provider   = aws.dr
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "replication_lag" {
  provider = aws.dr

  alarm_name          = "aurora-dr-replication-lag-${var.project_name}"
  alarm_description   = "Aurora DR replication lag exceeded threshold"
  namespace           = "AWS/RDS"
  metric_name         = "AuroraGlobalDBReplicationLag"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.replication_lag_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.dr.cluster_identifier
  }

  alarm_actions = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []
  ok_actions    = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  tags = {
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "aurora_cpu" {
  provider = aws.dr

  alarm_name          = "aurora-dr-cpu-high-${var.project_name}"
  alarm_description   = "Aurora DR CPU utilization > 80%"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.dr.cluster_identifier
  }

  alarm_actions = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  tags = {
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "aurora_free_storage" {
  provider = aws.dr

  alarm_name          = "aurora-dr-free-storage-low-${var.project_name}"
  alarm_description   = "Aurora DR free storage below 10GB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeLocalStorage"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10737418240 # 10 GB in bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.dr.cluster_identifier
  }

  alarm_actions = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  tags = {
    Environment = var.environment
  }
}
