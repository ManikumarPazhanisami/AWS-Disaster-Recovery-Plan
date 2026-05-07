#!/bin/bash
# =============================================================================
# s3-crr-setup.sh
# S3 Cross-Region Replication (CRR) Setup
# Phase 5: Enable versioning, create DR buckets, IAM role, replication rules
#
# Usage: ./s3-crr-setup.sh
# Prerequisites: AWS CLI configured, buckets listed below exist in us-east-1
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PRIMARY_REGION="us-east-1"
DR_REGION="us-west-1"

# Add all your bucket names here (without region suffix)
# Script will handle: mybucket-prod-useast1 → mybucket-prod-uswest1
BUCKET_BASES=(
  "mybucket-prod"
  # "myapp-assets"
  # "myapp-uploads"
  # "myapp-backups"
)

CRR_ROLE_NAME="s3-crr-role-dr"
CRR_POLICY_NAME="s3-crr-policy-dr"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✅  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ❌  $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
log "Checking AWS CLI..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text) \
  || fail "AWS CLI not configured."
ok "Account: $ACCOUNT_ID"

# ── Phase 5.1–5.3: Create DR Buckets & Enable Versioning ─────────────────────
declare -A BUCKET_MAP  # src → dst mapping

for BASE in "${BUCKET_BASES[@]}"; do
  SRC_BUCKET="${BASE}-useast1"
  DST_BUCKET="${BASE}-uswest1"
  BUCKET_MAP["$SRC_BUCKET"]="$DST_BUCKET"

  # Verify source bucket exists
  log "Verifying source bucket: s3://$SRC_BUCKET"
  aws s3api head-bucket --bucket "$SRC_BUCKET" --region "$PRIMARY_REGION" 2>/dev/null \
    || fail "Source bucket '$SRC_BUCKET' not found in $PRIMARY_REGION"

  # Enable versioning on source
  log "  Enabling versioning on source: $SRC_BUCKET"
  aws s3api put-bucket-versioning \
    --bucket "$SRC_BUCKET" \
    --versioning-configuration Status=Enabled \
    --region "$PRIMARY_REGION"

  # Create DR bucket
  log "  Creating DR bucket: $DST_BUCKET"
  if aws s3api head-bucket --bucket "$DST_BUCKET" --region "$DR_REGION" 2>/dev/null; then
    log "  DR bucket already exists: $DST_BUCKET"
  else
    aws s3api create-bucket \
      --bucket "$DST_BUCKET" \
      --region "$DR_REGION" \
      --create-bucket-configuration LocationConstraint="$DR_REGION"
    ok "  DR bucket created: $DST_BUCKET"
  fi

  # Enable versioning on DR bucket
  log "  Enabling versioning on DR bucket: $DST_BUCKET"
  aws s3api put-bucket-versioning \
    --bucket "$DST_BUCKET" \
    --versioning-configuration Status=Enabled \
    --region "$DR_REGION"

  # Block public access on DR bucket
  aws s3api put-public-access-block \
    --bucket "$DST_BUCKET" \
    --region "$DR_REGION" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  ok "  $SRC_BUCKET → $DST_BUCKET ready"
done

# ── Phase 5.4: Create IAM Role for CRR ───────────────────────────────────────
log "Creating IAM role for S3 CRR: $CRR_ROLE_NAME"

# Build trust policy
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "s3.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

# Check if role already exists
if aws iam get-role --role-name "$CRR_ROLE_NAME" > /dev/null 2>&1; then
  log "IAM role already exists: $CRR_ROLE_NAME"
  CRR_ROLE_ARN=$(aws iam get-role --role-name "$CRR_ROLE_NAME" --query 'Role.Arn' --output text)
else
  CRR_ROLE_ARN=$(aws iam create-role \
    --role-name "$CRR_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "S3 Cross-Region Replication role for DR" \
    --tags Key=Environment,Value=DR \
    --query 'Role.Arn' --output text)
  ok "IAM role created: $CRR_ROLE_ARN"
fi

# Build permissions policy with all source/dest buckets
SOURCE_RESOURCES=""
DEST_RESOURCES=""
for SRC in "${!BUCKET_MAP[@]}"; do
  DST="${BUCKET_MAP[$SRC]}"
  SOURCE_RESOURCES+="\"arn:aws:s3:::${SRC}\",\"arn:aws:s3:::${SRC}/*\","
  DEST_RESOURCES+="\"arn:aws:s3:::${DST}\",\"arn:aws:s3:::${DST}/*\","
done
SOURCE_RESOURCES="${SOURCE_RESOURCES%,}"
DEST_RESOURCES="${DEST_RESOURCES%,}"

PERMISSIONS_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetReplicationConfiguration",
        "s3:ListBucket"
      ],
      "Resource": [$SOURCE_RESOURCES]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObjectVersionForReplication",
        "s3:GetObjectVersionAcl",
        "s3:GetObjectVersionTagging"
      ],
      "Resource": [$SOURCE_RESOURCES]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ReplicateObject",
        "s3:ReplicateDelete",
        "s3:ReplicateTags"
      ],
      "Resource": [$DEST_RESOURCES]
    }
  ]
}
EOF
)

# Attach inline policy
aws iam put-role-policy \
  --role-name "$CRR_ROLE_NAME" \
  --policy-name "$CRR_POLICY_NAME" \
  --policy-document "$PERMISSIONS_POLICY"
ok "IAM permissions policy attached"

# ── Phase 5.5: Configure Replication Rules ────────────────────────────────────
log "Configuring S3 replication rules..."

RULE_INDEX=1
for SRC_BUCKET in "${!BUCKET_MAP[@]}"; do
  DST_BUCKET="${BUCKET_MAP[$SRC_BUCKET]}"
  DST_ARN="arn:aws:s3:::${DST_BUCKET}"

  REPLICATION_CONFIG=$(cat <<EOF
{
  "Role": "$CRR_ROLE_ARN",
  "Rules": [{
    "ID": "replicate-all-to-${DR_REGION}-${RULE_INDEX}",
    "Status": "Enabled",
    "Priority": $RULE_INDEX,
    "Filter": { "Prefix": "" },
    "Destination": {
      "Bucket": "$DST_ARN",
      "ReplicationTime": {
        "Status": "Enabled",
        "Time": { "Minutes": 15 }
      },
      "Metrics": {
        "Status": "Enabled",
        "EventThreshold": { "Minutes": 15 }
      },
      "StorageClass": "STANDARD"
    },
    "DeleteMarkerReplication": { "Status": "Enabled" }
  }]
}
EOF
)

  aws s3api put-bucket-replication \
    --bucket "$SRC_BUCKET" \
    --replication-configuration "$REPLICATION_CONFIG" \
    --region "$PRIMARY_REGION"

  ok "Replication rule set: $SRC_BUCKET → $DST_BUCKET"
  RULE_INDEX=$((RULE_INDEX + 1))
done

# ── Phase 5.6: Test Live Replication ─────────────────────────────────────────
log "Running live replication test..."

FIRST_SRC="${!BUCKET_MAP[@]}"  # just use the first bucket
FIRST_DST="${BUCKET_MAP[$FIRST_SRC]}"
TEST_FILE="dr-replication-test-$(date +%s).txt"

echo "DR replication test - $(date)" > "/tmp/$TEST_FILE"
aws s3 cp "/tmp/$TEST_FILE" "s3://${FIRST_SRC}/${TEST_FILE}" --region "$PRIMARY_REGION" > /dev/null
rm "/tmp/$TEST_FILE"

log "Test file uploaded: s3://$FIRST_SRC/$TEST_FILE"
log "Waiting up to 15 min for replication to $FIRST_DST..."

TIMEOUT=900
ELAPSED=0
while true; do
  if aws s3api head-object --bucket "$FIRST_DST" --key "$TEST_FILE" --region "$DR_REGION" > /dev/null 2>&1; then
    ok "Replication confirmed! File found in s3://$FIRST_DST/$TEST_FILE"
    # Clean up test files
    aws s3 rm "s3://${FIRST_SRC}/${TEST_FILE}" --region "$PRIMARY_REGION" > /dev/null
    aws s3 rm "s3://${FIRST_DST}/${TEST_FILE}" --region "$DR_REGION" > /dev/null
    break
  fi
  [[ $ELAPSED -ge $TIMEOUT ]] && { log "⚠️  Test file not yet in DR bucket. CRR may still be propagating. Check S3 console."; break; }
  sleep 30
  ELAPSED=$((ELAPSED + 30))
  log "  Still waiting... (${ELAPSED}s)"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  S3 CRR SETUP COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  IAM Role : $CRR_ROLE_ARN"
echo ""
echo "  Bucket mappings:"
for SRC in "${!BUCKET_MAP[@]}"; do
  echo "    s3://$SRC  →  s3://${BUCKET_MAP[$SRC]}"
done
echo ""
echo "  Verify replication at any time:"
echo "    aws s3api list-object-versions --bucket <src-bucket> --region $PRIMARY_REGION"
echo "    aws s3api list-object-versions --bucket <dst-bucket> --region $DR_REGION"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Next step → run: failover-execute.sh (only during an actual DR event)"
