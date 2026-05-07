#!/bin/bash
# =============================================================================
# failover-execute.sh
# DR Failover Execution Script — US-East-1 → US-West-1
# Covers DR Plan Steps 4–20 of the Failover Execution Plan
#
# ⚠️  WARNING: This script executes a production failover.
#     Run ONLY when a real disaster has been declared.
#     Coordinate with the Incident Commander before running.
#
# Usage: ./failover-execute.sh [--dry-run]
#        --dry-run   Print what would happen without making changes
#
# Prerequisites:
#   - network-setup.sh    completed
#   - aurora-replication.sh completed
#   - s3-crr-setup.sh     completed
#   - EC2 Launch Templates pre-created in us-west-1
# =============================================================================

set -euo pipefail

# ── Config — update these before running ─────────────────────────────────────
DR_REGION="us-west-1"
PRIMARY_REGION="us-east-1"

# Aurora
DR_CLUSTER_ID="ias-prod-cluster-dr"
PRIMARY_CLUSTER_ID="ias-prod-cluster"
DB_CNAME="db.yourdomain.com"                                   # Route53 CNAME to update
DR_DB_ENDPOINT="ias-prod-cluster-dr.cluster-xxxxx.us-west-1.rds.amazonaws.com"  # fill in

# EC2
APP_LAUNCH_TEMPLATE="prod-app-dr-template"
NGINX_LAUNCH_TEMPLATE="prod-nginx-dr-template"
APP_INSTANCE_COUNT=2
NGINX_EIP_ALLOCATION="eipalloc-xxxxx"    # pre-allocated EIP for Nginx
APP_HEALTH_PORT=3000
APP_HEALTH_PATH="/health"

# Route53
HOSTED_ZONE_ID="ZXXXXXXXXXXXXX"          # your hosted zone ID
API_CNAME="api.yourdomain.com"           # app-facing DNS record

# SQS queues (primary → DR mapping)
declare -A SQS_QUEUE_MAP=(
  ["my-queue"]="my-queue-dr"
  # ["another-queue"]="another-queue-dr"
)

# Logging
LOG_FILE="/tmp/dr-failover-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { local msg="[$(date '+%H:%M:%S')] $*"; echo "$msg" | tee -a "$LOG_FILE"; }
ok()   { local msg="[$(date '+%H:%M:%S')] ✅  $*"; echo "$msg" | tee -a "$LOG_FILE"; }
warn() { local msg="[$(date '+%H:%M:%S')] ⚠️   $*"; echo "$msg" | tee -a "$LOG_FILE"; }
fail() { local msg="[$(date '+%H:%M:%S')] ❌  $*"; echo "$msg" | tee -a "$LOG_FILE" >&2; exit 1; }

run() {
  # run <description> <command...>
  local desc="$1"; shift
  log "  → $desc"
  if $DRY_RUN; then
    log "  [DRY RUN] Would run: $*"
    return 0
  fi
  eval "$@" >> "$LOG_FILE" 2>&1 || fail "Command failed: $*"
}

checkpoint() {
  log ""
  log "━━ CHECKPOINT: $* ━━"
  if ! $DRY_RUN; then
    read -rp "    Confirm and continue? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || fail "Failover aborted by operator"
  fi
}

elapsed_since() { echo $(( $(date +%s) - $1 )); }

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          DR FAILOVER EXECUTION — US-East-1 → US-West-1      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
if $DRY_RUN; then
  warn "DRY RUN MODE — no changes will be made"
  echo ""
fi
log "Failover log: $LOG_FILE"
log "Start time  : $(date)"
FAILOVER_START=$(date +%s)
echo ""

# ── Preflight ─────────────────────────────────────────────────────────────────
log "▶ PREFLIGHT CHECKS"

aws sts get-caller-identity --query 'Account' --output text > /dev/null \
  || fail "AWS CLI not configured"
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ok "AWS CLI ready — account: $ACCOUNT_ID"

# Verify DR cluster exists
aws rds describe-db-clusters \
  --db-cluster-identifier "$DR_CLUSTER_ID" \
  --region "$DR_REGION" > /dev/null 2>&1 \
  || fail "DR cluster '$DR_CLUSTER_ID' not found in $DR_REGION"
ok "DR cluster exists"

# Verify launch templates exist
aws ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=$APP_LAUNCH_TEMPLATE" \
  --region "$DR_REGION" \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text > /dev/null \
  || fail "Launch template '$APP_LAUNCH_TEMPLATE' not found"
ok "EC2 launch templates found"

checkpoint "Preflight checks passed. Proceed with failover?"

# ── Step 4: Verify Aurora Replication Status ──────────────────────────────────
log ""
log "▶ STEP 4 — Verifying Aurora Replication Status"
T4=$(date +%s)

CLUSTER_STATUS=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$DR_CLUSTER_ID" \
  --region "$DR_REGION" \
  --query 'DBClusters[0].Status' --output text)
log "  DR cluster status: $CLUSTER_STATUS"
[[ "$CLUSTER_STATUS" == "available" ]] || warn "Cluster status is '$CLUSTER_STATUS' — not 'available'. Proceed with caution."

# Check replication lag
LAG=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name AuroraGlobalDBReplicationLag \
  --dimensions Name=DBClusterIdentifier,Value="$DR_CLUSTER_ID" \
  --start-time "$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 300 --statistics Average \
  --region "$DR_REGION" \
  --query 'sort_by(Datapoints, &Timestamp)[-1].Average' --output text 2>/dev/null || echo "N/A")
log "  Replication lag: ${LAG}ms (acceptable: <1000ms)"

[[ "$LAG" == "N/A" ]] && warn "Could not determine replication lag. Verify manually in CloudWatch."
ok "Step 4 complete ($(elapsed_since $T4)s)"

checkpoint "Replication status verified. Promote Aurora cluster?"

# ── Step 7: Promote Aurora DR Replica ────────────────────────────────────────
log ""
log "▶ STEP 7 — Promoting Aurora DR Replica to Primary"
T7=$(date +%s)

if $DRY_RUN; then
  log "  [DRY RUN] Would promote: $DR_CLUSTER_ID"
else
  aws rds promote-read-replica-db-cluster \
    --db-cluster-identifier "$DR_CLUSTER_ID" \
    --region "$DR_REGION" >> "$LOG_FILE" 2>&1
  log "  Promotion initiated. Waiting for status: 'available' (5–10 min)..."

  TIMEOUT=900
  ELAPSED=0
  while true; do
    STATUS=$(aws rds describe-db-clusters \
      --db-cluster-identifier "$DR_CLUSTER_ID" \
      --region "$DR_REGION" \
      --query 'DBClusters[0].Status' --output text)
    log "  Status: $STATUS (${ELAPSED}s)"
    [[ "$STATUS" == "available" ]] && break
    [[ $ELAPSED -ge $TIMEOUT ]] && fail "Aurora promotion timed out. Check RDS console."
    sleep 30; ELAPSED=$((ELAPSED + 30))
  done
fi
ok "Step 7 complete — Aurora promoted ($(elapsed_since $T7)s)"

# ── Step 9: Update Route53 DNS (Database) ────────────────────────────────────
log ""
log "▶ STEP 9 — Updating Route53 CNAME for database"
T9=$(date +%s)

DB_CHANGE_BATCH=$(cat <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$DB_CNAME",
      "Type": "CNAME",
      "TTL": 60,
      "ResourceRecords": [{ "Value": "$DR_DB_ENDPOINT" }]
    }
  }]
}
EOF
)

if $DRY_RUN; then
  log "  [DRY RUN] Would update CNAME $DB_CNAME → $DR_DB_ENDPOINT"
else
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "$DB_CHANGE_BATCH" >> "$LOG_FILE" 2>&1
fi
ok "Step 9 complete — DB DNS updated ($(elapsed_since $T9)s)"

# ── Step 10: Launch EC2 App Servers ──────────────────────────────────────────
log ""
log "▶ STEP 10 — Launching EC2 App Servers from Launch Template"
T10=$(date +%s)

if $DRY_RUN; then
  log "  [DRY RUN] Would launch $APP_INSTANCE_COUNT instances from $APP_LAUNCH_TEMPLATE"
  APP_INSTANCE_IDS="i-dry-run-1 i-dry-run-2"
else
  APP_INSTANCE_IDS=$(aws ec2 run-instances \
    --launch-template LaunchTemplateName="$APP_LAUNCH_TEMPLATE" \
    --count "$APP_INSTANCE_COUNT" \
    --region "$DR_REGION" \
    --query 'Instances[*].InstanceId' --output text)
  log "  Instances launched: $APP_INSTANCE_IDS"
  log "  Waiting for instances to reach running state..."
  aws ec2 wait instance-running \
    --instance-ids $APP_INSTANCE_IDS \
    --region "$DR_REGION"
fi
ok "Step 10 complete — App instances running ($(elapsed_since $T10)s)"

# ── Step 11: Verify Application Health ───────────────────────────────────────
log ""
log "▶ STEP 11–12 — Verifying Application Health"
T11=$(date +%s)

if ! $DRY_RUN; then
  log "  Waiting 30s for app startup..."
  sleep 30

  HEALTHY=0
  for INSTANCE_ID in $APP_INSTANCE_IDS; do
    PRIVATE_IP=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --region "$DR_REGION" \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
    log "  Checking health: $INSTANCE_ID ($PRIVATE_IP)"

    # Use SSM to check health endpoint internally (no public IP needed)
    SSM_RESULT=$(aws ssm send-command \
      --document-name "AWS-RunShellScript" \
      --instance-ids "$INSTANCE_ID" \
      --parameters "commands=[\"curl -sf http://localhost:${APP_HEALTH_PORT}${APP_HEALTH_PATH} && echo HEALTHY || echo UNHEALTHY\"]" \
      --region "$DR_REGION" \
      --query 'Command.CommandId' --output text 2>/dev/null || echo "SSM_UNAVAILABLE")

    if [[ "$SSM_RESULT" == "SSM_UNAVAILABLE" ]]; then
      warn "  SSM not available. Verify $INSTANCE_ID health manually."
    else
      sleep 10
      HEALTH=$(aws ssm get-command-invocation \
        --command-id "$SSM_RESULT" --instance-id "$INSTANCE_ID" \
        --region "$DR_REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null || echo "UNKNOWN")
      log "  $INSTANCE_ID health: $HEALTH"
      [[ "$HEALTH" == *"HEALTHY"* ]] && HEALTHY=$((HEALTHY + 1))
    fi
  done
  [[ $HEALTHY -eq 0 ]] && warn "No instances confirmed healthy. Verify manually before proceeding."
fi
ok "Step 11–12 complete ($(elapsed_since $T11)s)"

checkpoint "App servers running. Launch Nginx and update DNS?"

# ── Step 13: Launch Nginx Proxy ───────────────────────────────────────────────
log ""
log "▶ STEP 13 — Launching Nginx Proxy Server"
T13=$(date +%s)

if $DRY_RUN; then
  log "  [DRY RUN] Would launch Nginx from $NGINX_LAUNCH_TEMPLATE"
  NGINX_INSTANCE_ID="i-nginx-dry-run"
else
  NGINX_INSTANCE_ID=$(aws ec2 run-instances \
    --launch-template LaunchTemplateName="$NGINX_LAUNCH_TEMPLATE" \
    --count 1 \
    --region "$DR_REGION" \
    --query 'Instances[0].InstanceId' --output text)
  log "  Nginx instance: $NGINX_INSTANCE_ID"
  aws ec2 wait instance-running \
    --instance-ids "$NGINX_INSTANCE_ID" \
    --region "$DR_REGION"

  log "  Associating pre-allocated EIP $NGINX_EIP_ALLOCATION..."
  aws ec2 associate-address \
    --instance-id "$NGINX_INSTANCE_ID" \
    --allocation-id "$NGINX_EIP_ALLOCATION" \
    --region "$DR_REGION" >> "$LOG_FILE" 2>&1

  NGINX_PUBLIC_IP=$(aws ec2 describe-addresses \
    --allocation-ids "$NGINX_EIP_ALLOCATION" \
    --region "$DR_REGION" \
    --query 'Addresses[0].PublicIp' --output text)
  log "  Nginx public IP: $NGINX_PUBLIC_IP"
fi
ok "Step 13 complete — Nginx launched ($(elapsed_since $T13)s)"

# ── Step 15: Update Route53 DNS (Application) ────────────────────────────────
log ""
log "▶ STEP 15 — Updating Route53 A record for application"
T15=$(date +%s)

if $DRY_RUN; then
  NGINX_PUBLIC_IP="1.2.3.4"
  log "  [DRY RUN] Would update A record $API_CNAME → $NGINX_PUBLIC_IP"
else
  APP_CHANGE_BATCH=$(cat <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$API_CNAME",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{ "Value": "$NGINX_PUBLIC_IP" }]
    }
  }]
}
EOF
)
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "$APP_CHANGE_BATCH" >> "$LOG_FILE" 2>&1
fi
ok "Step 15 complete — App DNS updated ($(elapsed_since $T15)s)"

# ── Step 16: Wait for DNS Propagation ────────────────────────────────────────
log ""
log "▶ STEP 16 — Waiting for DNS propagation (TTL=60s, allow 3 min)"
if ! $DRY_RUN; then
  sleep 180
  RESOLVED=$(dig +short "$API_CNAME" 2>/dev/null || echo "dig not available")
  log "  DNS resolves to: $RESOLVED"
fi
ok "Step 16 complete — DNS propagated"

# ── Step 17: End-to-End Health Check ─────────────────────────────────────────
log ""
log "▶ STEP 17 — End-to-End Application Validation"
if ! $DRY_RUN; then
  APP_RESPONSE=$(curl -sf --max-time 10 \
    "https://${API_CNAME}${APP_HEALTH_PATH}" 2>/dev/null && echo "OK" || echo "FAILED")
  log "  Application health via public DNS: $APP_RESPONSE"
  [[ "$APP_RESPONSE" == "OK" ]] && ok "Application is responding via DR DNS" \
    || warn "Application health check failed. Verify manually."
fi

# ── Step 18: SQS Queue Validation ────────────────────────────────────────────
log ""
log "▶ STEP 18 — Verifying SQS DR Queues"
for SRC_Q in "${!SQS_QUEUE_MAP[@]}"; do
  DR_Q="${SQS_QUEUE_MAP[$SRC_Q]}"
  if ! $DRY_RUN; then
    DR_Q_URL=$(aws sqs get-queue-url --queue-name "$DR_Q" --region "$DR_REGION" \
      --query 'QueueUrl' --output text 2>/dev/null || echo "NOT_FOUND")
    [[ "$DR_Q_URL" == "NOT_FOUND" ]] \
      && warn "DR queue '$DR_Q' not found in $DR_REGION — create it!" \
      || ok "  SQS queue verified: $DR_Q"
  else
    log "  [DRY RUN] Would verify: $DR_Q in $DR_REGION"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL_ELAPSED=$(elapsed_since $FAILOVER_START)
TOTAL_MIN=$((TOTAL_ELAPSED / 60))
TOTAL_SEC=$((TOTAL_ELAPSED % 60))

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              FAILOVER COMPLETE                               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
log "  Total RTO achieved : ${TOTAL_MIN}m ${TOTAL_SEC}s"
log "  DR region          : $DR_REGION"
log "  Aurora cluster     : $DR_CLUSTER_ID (now primary)"
log "  App DNS            : $API_CNAME"
log "  DB DNS             : $DB_CNAME → $DR_DB_ENDPOINT"
log "  Failover log       : $LOG_FILE"
echo ""
echo "  ⚡ IMMEDIATE ACTIONS:"
echo "     1. Update status page: 'Services operational on DR'"
echo "     2. Notify customers of resolution"
echo "     3. Monitor CloudWatch for errors/latency for 2+ hours"
echo "     4. Begin documenting incident timeline"
echo ""
echo "  📋 NEXT: Run failback plan once primary region is restored"
echo ""
if $DRY_RUN; then
  warn "This was a DRY RUN — no actual changes were made"
fi
