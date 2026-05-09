#!/bin/bash
# =============================================================================
# ami-sync.sh
# Automates AMI copying from US-East-1 to US-West-1
# Usage: ./ami-sync.sh <ami-id-in-us-east-1> [description]
# =============================================================================

set -euo pipefail

PRIMARY_REGION="us-east-1"
DR_REGION="us-west-1"

AMI_ID="${1:-}"
DESC="${2:-DR copy from $PRIMARY_REGION}"

if [[ -z "$AMI_ID" ]]; then
    echo "Usage: $0 <ami-id-in-us-east-1> [description]"
    exit 1
fi

echo "--- AMI Sync: $PRIMARY_REGION -> $DR_REGION ---"
echo "Source AMI: $AMI_ID"

# 1. Get Source AMI Name
AMI_NAME=$(aws ec2 describe-images --region "$PRIMARY_REGION" --image-ids "$AMI_ID" --query 'Images[0].Name' --output text)
echo "AMI Name:   $AMI_NAME"

# 2. Start Copy
echo "Starting copy to $DR_REGION..."
NEW_AMI_ID=$(aws ec2 copy-image \
    --source-region "$PRIMARY_REGION" \
    --source-image-id "$AMI_ID" \
    --name "$AMI_NAME-dr-$(date +%Y%m%d)" \
    --description "$DESC" \
    --region "$DR_REGION" \
    --output text --query 'ImageId')

echo "New AMI ID in $DR_REGION: $NEW_AMI_ID"
echo "Waiting for AMI to become available (this can take 5-10 mins)..."

# 3. Wait for completion
aws ec2 wait image-available --region "$DR_REGION" --image-ids "$NEW_AMI_ID"

echo "✅ AMI is now AVAILABLE in $DR_REGION"
echo "------------------------------------------------"
echo "Next step: Update your terraform.tfvars with:"
echo "app_ami_id = \"$NEW_AMI_ID\""
echo "------------------------------------------------"
