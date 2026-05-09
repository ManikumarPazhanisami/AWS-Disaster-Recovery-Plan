# =============================================================================
# compute/main.tf
# Phases 5–8: S3 CRR, EC2 Launch Templates, SQS, Route53 Failover,
#             CloudWatch Alarms, EIP for Nginx
# =============================================================================

# ── Data Sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# ── Elastic IP for Nginx (pre-allocated, associated during failover) ───────────
resource "aws_eip" "nginx" {
  domain = "vpc"

  tags = {
    Name        = "eip-nginx-${var.project_name}-dr"
    Environment = var.environment
    Usage       = "Nginx proxy - associate during failover"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: S3 Cross-Region Replication
# ─────────────────────────────────────────────────────────────────────────────

# ── IAM Role for S3 CRR ───────────────────────────────────────────────────────
resource "aws_iam_role" "s3_crr" {
  name = "s3-crr-role-${var.project_name}-dr"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Environment = var.environment }
}

resource "aws_iam_role_policy" "s3_crr" {
  name = "s3-crr-policy-${var.project_name}-dr"
  role = aws_iam_role.s3_crr.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = [
          for b in var.s3_bucket_names :
          "arn:aws:s3:::${b}-useast1"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = [
          for b in var.s3_bucket_names :
          "arn:aws:s3:::${b}-useast1/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Resource = [
          for b in var.s3_bucket_names :
          "arn:aws:s3:::${b}-uswest1/*"
        ]
      }
    ]
  })
}

# ── DR S3 Buckets ─────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "dr" {
  count  = length(var.s3_bucket_names)
  bucket = "${var.s3_bucket_names[count.index]}-uswest1"

  tags = {
    Name        = "${var.s3_bucket_names[count.index]}-uswest1"
    Environment = var.environment
    Role        = "DR-Replica"
  }
}

resource "aws_s3_bucket_versioning" "dr" {
  count  = length(var.s3_bucket_names)
  bucket = aws_s3_bucket.dr[count.index].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "dr" {
  count  = length(var.s3_bucket_names)
  bucket = aws_s3_bucket.dr[count.index].id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6: EC2 Launch Templates
# ─────────────────────────────────────────────────────────────────────────────

# ── IAM Role for EC2 instances ────────────────────────────────────────────────
resource "aws_iam_role" "ec2_app" {
  name = "ec2-app-role-${var.project_name}-dr"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Environment = var.environment }
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch" {
  role       = aws_iam_role.ec2_app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "ec2_secrets" {
  count = var.secret_arn != "" ? 1 : 0
  name  = "ec2-secrets-policy-${var.project_name}-dr"
  role  = aws_iam_role.ec2_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [var.secret_arn]
      },
      {
        Effect = "Allow"
        Action = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_app" {
  name = "ec2-app-profile-${var.project_name}-dr"
  role = aws_iam_role.ec2_app.name
}

# ── App Server Launch Template ────────────────────────────────────────────────
resource "aws_launch_template" "app" {
  name        = "prod-app-${var.project_name}-dr-template"
  description = "DR Node.js app server launch template"

  image_id      = var.app_ami_id != "" ? var.app_ami_id : null
  instance_type = var.app_instance_type
  key_name      = var.key_pair_name

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_app.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.sg_app_id]
    subnet_id                   = var.app_subnet_ids[0]
  }

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 required
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # DR startup script — customize for your app
    set -e
    cd /home/ec2-user/app
    # Update DB endpoint from Secrets Manager or env file
    # systemctl start myapp
    echo "DR instance started at $(date)" >> /var/log/dr-startup.log
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-app-dr"
      Environment = var.environment
      Role        = "AppServer"
    }
  }

  tags = {
    Name        = "prod-app-${var.project_name}-dr-template"
    Environment = var.environment
  }
}

# ── Nginx Proxy Launch Template ───────────────────────────────────────────────
resource "aws_launch_template" "nginx" {
  name        = "prod-nginx-${var.project_name}-dr-template"
  description = "DR Nginx reverse proxy launch template"

  image_id      = var.nginx_ami_id != "" ? var.nginx_ami_id : null
  instance_type = var.nginx_instance_type
  key_name      = var.key_pair_name

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_app.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.sg_nginx_id]
    subnet_id                   = var.public_subnet_ids[0]
  }

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 10
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-nginx-dr"
      Environment = var.environment
      Role        = "NginxProxy"
    }
  }

  tags = {
    Name        = "prod-nginx-${var.project_name}-dr-template"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 7: SQS DR Queues
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "dr_dlq" {
  name                      = "${var.project_name}-queue-dr-dlq"
  message_retention_seconds = 1209600  # 14 days
  kms_master_key_id         = "alias/aws/sqs"

  tags = {
    Name        = "${var.project_name}-queue-dr-dlq"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "dr" {
  name                       = "${var.project_name}-queue-dr"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600  # 4 days
  kms_master_key_id          = "alias/aws/sqs"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dr_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name        = "${var.project_name}-queue-dr"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 8: Route53 Failover DNS
# ─────────────────────────────────────────────────────────────────────────────

# Route53 health check on primary region
resource "aws_route53_health_check" "primary" {
  fqdn              = var.api_domain
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 10

  tags = {
    Name        = "hc-primary-${var.project_name}"
    Environment = var.environment
  }
}

# Primary DNS record (FAILOVER PRIMARY) — points to us-east-1
resource "aws_route53_record" "primary" {
  count   = var.hosted_zone_id != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.api_domain
  type    = "A"
  ttl     = 60

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier = "primary"
  health_check_id = aws_route53_health_check.primary.id

  records = ["0.0.0.0"]  # Replace with your primary Nginx EIP
}

# DR DNS record (FAILOVER SECONDARY) — points to us-west-1 Nginx EIP
resource "aws_route53_record" "dr" {
  count   = var.hosted_zone_id != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.api_domain
  type    = "A"
  ttl     = 60

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier = "dr-secondary"
  records        = [aws_eip.nginx.public_ip]
}

# DB CNAME record
resource "aws_route53_record" "db_cname" {
  count   = var.hosted_zone_id != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.db_cname
  type    = "CNAME"
  ttl     = 60
  records = [var.dr_db_endpoint]
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudWatch Alarms for EC2 & Route53
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "health_check_status" {
  alarm_name          = "route53-health-check-failed-${var.project_name}"
  alarm_description   = "Primary region Route53 health check failing"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }

  alarm_actions = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  tags = { Environment = var.environment }
}
