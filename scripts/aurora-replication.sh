#!/bin/bash
# =============================================================================
# aurora-replication.sh
# Aurora MySQL Serverless v2 Cross-Region Replication Setup
# Phase 4: KMS key, cross-region read replica, CloudWatch alarms
#
# Usage: ./aurora-replication.sh
# Prerequisites: network-setup.sh must have been run first
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PRIMARY_REGION="us-east-1"
DR_REGION="us-west-1"

PRIMARY_CLUSTER_ID="ias-prod-cluster"
DR_CLUSTER_ID="ias-prod-cluster-dr"
DR_INSTANCE_ID="ias-prod-instance-1-dr"

DB_SUBNET_GROUP="prod-dr-subnet-group"    # created by network-setup.sh
SG_AURORA="sg-aurora-mysql-dr"            # replace with actual SG ID after running network-setup.sh

SNS_ALARM_ARN=""   # Optional: fill in your SNS topic ARN for CloudWatch alarms

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✅  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ❌  $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
log "Checking AWS CLI..."
aws sts get-caller-identity --query 'Account' --output text > /dev/null \
  || fail "AWS CLI not configured."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ok "Account: $ACCOUNT_ID"

# Verify primary cluster exists
log "Verifying primary cluster exists in $PRIMARY_REGION..."
aws rds describe-db-clusters \
  --db-cluster-identifier "$PRIMARY_CLUSTER_ID" \
  --region "$PRIMARY_REGION" \
  --query 'DBClusters[0].Status' --output text > /dev/null \
  || fail "Primary cluster '$PRIMARY_CLUSTER_ID' not found in $PRIMARY_REGION"
ok "Primary cluster found"

# ── Phase 4.1: KMS Key ────────────────────────────────────────────────────────
log "Creating KMS key for Aurora DR encryption in $DR_REGION..."
KMS_KEY_ID=$(aws kms create-key \
  --description "Aurora DR encryption key - us-west-1" \
  --region "$DR_REGION" \
  --tags TagKey=Environment,TagValue=DR TagKey=Purpose,TagValue=AuroraEncryption \
  --query 'KeyMetadata.KeyId' --output text)

aws kms create-alias \
  --alias-name "alias/aurora-dr" \
  --target-key-id "$KMS_KEY_ID" \
  --region "$DR_REGION"

KMS_KEY_ARN=$(aws kms describe-key \
  --key-id "$KMS_KEY_ID" \
  --region "$DR_REGION" \
  --query 'KeyMetadata.Arn' --output text)

ok "KMS key created: $KMS_KEY_ARN"

# ── Phase 4.2: DB Subnet Group ────────────────────────────────────────────────
# Verify subnet group exists (should be created by network-setup.sh)
log "Verifying DB subnet group '$DB_SUBNET_GROUP'..."
aws rds describe-db-subnet-groups \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --region "$DR_REGION" \
  --query 'DBSubnetGroups[0].DBSubnetGroupName' --output text > /dev/null \
  || fail "DB subnet group '$DB_SUBNET_GROUP' not found. Run network-setup.sh first."
ok "DB subnet group verified"

# ── Phase 4.3: Get actual SG ID if name given ─────────────────────────────────
if [[ "$SG_AURORA" == sg-aurora-mysql-dr ]]; then
  log "Resolving security group ID for 'sg-aurora-mysql-dr'..."
  SG_AURORA_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=sg-aurora-mysql-dr" \
    --region "$DR_REGION" \
    --query 'SecurityGroups[0].GroupId' --output text)
  [[ "$SG_AURORA_ID" == "None" ]] && fail "Security group 'sg-aurora-mysql-dr' not found. Run network-setup.sh first."
  SG_AURORA="$SG_AURORA_ID"
  ok "Security group resolved: $SG_AURORA"
fi

# ── Phase 4.4: Get Primary Cluster ARN ───────────────────────────────────────
log "Getting primary cluster ARN..."
PRIMARY_CLUSTER_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$PRIMARY_CLUSTER_ID" \
  --region "$PRIMARY_REGION" \
  --query 'DBClusters[0].DBClusterArn' --output text)
ok "Primary cluster ARN: $PRIMARY_CLUSTER_ARN"

# ── Phase 4.5: Create Cross-Region Read Replica ───────────────────────────────
log "Creating Aurora cross-region read replica in $DR_REGION..."
log "This will take 20–30 minutes. Please wait..."

aws rds create-db-cluster \
  --db-cluster-identifier "$DR_CLUSTER_ID" \
  --region "$DR_REGION" \
  --replication-source-identifier "$PRIMARY_CLUSTER_ARN" \
  --engine "aurora-mysql" \
  --engine-version "8.0.mysql_aurora.3.08.2" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --vpc-security-group-ids "$SG_AURORA" \
  --kms-key-id "$KMS_KEY_ARN" \
  --storage-encrypted \
  --enable-cloudwatch-logs-exports '["error","slowquery","audit"]' \
  --tags Key=Environment,Value=DR Key=Name,Value="$DR_CLUSTER_ID" \
  > /dev/null

ok "DR cluster creation initiated: $DR_CLUSTER_ID"

# Add Serverless v2 instance to the cluster
log "Adding Serverless v2 instance to DR cluster..."
aws rds create-db-instance \
  --db-instance-identifier "$DR_INSTANCE_ID" \
  --db-cluster-identifier "$DR_CLUSTER_ID" \
  --db-instance-class "db.serverless" \
  --engine "aurora-mysql" \
  --region "$DR_REGION" \
  --enable-performance-insights \
  --performance-insights-retention-period 7 \
  --monitoring-interval 60 \
  --tags Key=Environment,Value=DR Key=Name,Value="$DR_INSTANCE_ID" \
  > /dev/null

# ── Phase 4.6: Wait for cluster to become available ───────────────────────────
log "Waiting for DR cluster to become available (up to 45 min)..."
TIMEOUT=2700  # 45 minutes
ELAPSED=0
INTERVAL=30

while true; do
  STATUS=$(aws rds describe-db-clusters \
    --db-cluster-identifier "$DR_CLUSTER_ID" \
    --region "$DR_REGION" \
    --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "creating")

  log "  Cluster status: $STATUS (${ELAPSED}s elapsed)"

  [[ "$STATUS" == "available" ]] && break
  [[ $ELAPSED -ge $TIMEOUT ]] && fail "Timed out waiting for cluster. Check RDS Console."

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

ok "DR cluster is available: $DR_CLUSTER_ID"

# ── Phase 4.7: Get DR Cluster Endpoint ───────────────────────────────────────
DR_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$DR_CLUSTER_ID" \
  --region "$DR_REGION" \
  --query 'DBClusters[0].ReaderEndpoint' --output text)
ok "DR cluster reader endpoint: $DR_ENDPOINT"

# ── Phase 4.8: Verify Replication Lag ────────────────────────────────────────
log "Checking replication lag in CloudWatch..."
LAG=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name AuroraGlobalDBReplicationLag \
  --dimensions Name=DBClusterIdentifier,Value="$DR_CLUSTER_ID" \
  --start-time "$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 300 \
  --statistics Average \
  --region "$DR_REGION" \
  --query 'Datapoints[0].Average' --output text 2>/dev/null || echo "N/A")
log "  Replication lag: ${LAG}ms (target: <1000ms)"

# ── Phase 4.9: CloudWatch Alarms ─────────────────────────────────────────────
log "Creating CloudWatch alarm for replication lag..."

ALARM_ACTIONS=""
[[ -n "$SNS_ALARM_ARN" ]] && ALARM_ACTIONS="--alarm-actions $SNS_ALARM_ARN"

aws cloudwatch put-metric-alarm \
  --alarm-name "aurora-dr-replication-lag-high" \
  --alarm-description "Aurora DR replication lag exceeded 5 seconds" \
  --namespace AWS/RDS \
  --metric-name AuroraGlobalDBReplicationLag \
  --dimensions Name=DBClusterIdentifier,Value="$DR_CLUSTER_ID" \
  --statistic Average \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 5000 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  $ALARM_ACTIONS \
  --region "$DR_REGION"

aws cloudwatch put-metric-alarm \
  --alarm-name "aurora-dr-cpu-high" \
  --alarm-description "Aurora DR CPU utilization > 80%" \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBClusterIdentifier,Value="$DR_CLUSTER_ID" \
  --statistic Average \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  $ALARM_ACTIONS \
  --region "$DR_REGION"

ok "CloudWatch alarms created"

# ── Phase 4.10: Serverless v2 Capacity Config ────────────────────────────────
log "Configuring Aurora Serverless v2 capacity (1–8 ACUs)..."
aws rds modify-db-cluster \
  --db-cluster-identifier "$DR_CLUSTER_ID" \
  --serverless-v2-scaling-configuration MinCapacity=1,MaxCapacity=8 \
  --region "$DR_REGION" \
  --apply-immediately > /dev/null
ok "Serverless v2 scaling configured: 1–8 ACUs"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AURORA REPLICATION COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Primary cluster : $PRIMARY_CLUSTER_ID ($PRIMARY_REGION)"
echo "  DR cluster      : $DR_CLUSTER_ID ($DR_REGION)"
echo "  DR endpoint     : $DR_ENDPOINT"
echo "  KMS key ARN     : $KMS_KEY_ARN"
echo "  Replication lag : ${LAG}ms"
echo ""
echo "  Test connectivity:"
echo "  mysql -h $DR_ENDPOINT -u admin -p \\"
echo "    -e \"SELECT NOW(); SELECT COUNT(*) FROM information_schema.tables;\""
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Next step → run: s3-crr-setup.sh"
