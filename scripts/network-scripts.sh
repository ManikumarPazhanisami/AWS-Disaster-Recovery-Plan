#!/bin/bash
# =============================================================================
# network-setup.sh
# AWS DR Network Infrastructure Setup - US-West-1
# Phase 2 & Phase 3: VPC, Subnets, NAT, Security Groups
#
# Usage: ./network-setup.sh
# Prerequisites: AWS CLI configured with sufficient IAM permissions
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
DR_REGION="us-west-1"
VPC_CIDR="10.1.0.0/16"
VPC_NAME="vpc-dr-uswest1"

PUB_SUBNET_1A_CIDR="10.1.1.0/24"
PUB_SUBNET_1B_CIDR="10.1.2.0/24"
APP_SUBNET_1A_CIDR="10.1.10.0/24"
APP_SUBNET_1B_CIDR="10.1.11.0/24"
DB_SUBNET_1A_CIDR="10.1.20.0/24"
DB_SUBNET_1B_CIDR="10.1.21.0/24"

AZ_1A="us-west-1a"
AZ_1B="us-west-1b"

PRIMARY_VPC_CIDR="10.0.0.0/16"   # your primary us-east-1 VPC CIDR

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✅  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ❌  $*" >&2; exit 1; }

wait_available() {
  local resource_type=$1 resource_id=$2
  log "Waiting for $resource_type $resource_id to become available..."
  aws ec2 wait "${resource_type}-available" \
    --"${resource_type}-ids" "$resource_id" \
    --region "$DR_REGION" 2>/dev/null || true
}

# ── Preflight ─────────────────────────────────────────────────────────────────
log "Checking AWS CLI..."
aws sts get-caller-identity --query 'Account' --output text > /dev/null \
  || fail "AWS CLI not configured. Run: aws configure"
ok "AWS CLI ready. Region: $DR_REGION"

# ── Phase 2.1: VPC ────────────────────────────────────────────────────────────
log "Creating VPC ($VPC_CIDR)..."
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --region "$DR_REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Environment,Value=DR}]" \
  --query 'Vpc.VpcId' --output text)
ok "VPC created: $VPC_ID"

# Phase 2.2: Enable DNS
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$DR_REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support    --region "$DR_REGION"
ok "DNS hostnames & support enabled"

# ── Phase 2.3: Internet Gateway ───────────────────────────────────────────────
log "Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$DR_REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=igw-dr-uswest1}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region "$DR_REGION"
ok "Internet Gateway attached: $IGW_ID"

# ── Phase 2.4–2.6: Subnets ───────────────────────────────────────────────────
log "Creating subnets..."

create_subnet() {
  local cidr=$1 az=$2 name=$3
  aws ec2 create-subnet \
    --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
    --region "$DR_REGION" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name},{Key=Environment,Value=DR}]" \
    --query 'Subnet.SubnetId' --output text
}

PUB_SUBNET_1A=$(create_subnet "$PUB_SUBNET_1A_CIDR" "$AZ_1A" "subnet-dr-public-1a")
PUB_SUBNET_1B=$(create_subnet "$PUB_SUBNET_1B_CIDR" "$AZ_1B" "subnet-dr-public-1b")
APP_SUBNET_1A=$(create_subnet "$APP_SUBNET_1A_CIDR" "$AZ_1A" "subnet-dr-app-1a")
APP_SUBNET_1B=$(create_subnet "$APP_SUBNET_1B_CIDR" "$AZ_1B" "subnet-dr-app-1b")
DB_SUBNET_1A=$(create_subnet  "$DB_SUBNET_1A_CIDR"  "$AZ_1A" "subnet-dr-db-1a")
DB_SUBNET_1B=$(create_subnet  "$DB_SUBNET_1B_CIDR"  "$AZ_1B" "subnet-dr-db-1b")

# Enable auto-assign public IP for public subnets
aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUBNET_1A" --map-public-ip-on-launch --region "$DR_REGION"
aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUBNET_1B" --map-public-ip-on-launch --region "$DR_REGION"
ok "Subnets created: pub-1a=$PUB_SUBNET_1A pub-1b=$PUB_SUBNET_1B app-1a=$APP_SUBNET_1A app-1b=$APP_SUBNET_1B db-1a=$DB_SUBNET_1A db-1b=$DB_SUBNET_1B"

# ── Phase 2.7–2.8: NAT Gateways ──────────────────────────────────────────────
log "Allocating Elastic IPs for NAT Gateways..."
EIP_1A=$(aws ec2 allocate-address --domain vpc --region "$DR_REGION" --query 'AllocationId' --output text)
EIP_1B=$(aws ec2 allocate-address --domain vpc --region "$DR_REGION" --query 'AllocationId' --output text)
ok "EIPs allocated: 1a=$EIP_1A 1b=$EIP_1B"

log "Creating NAT Gateways (this takes 2–3 min)..."
NAT_1A=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUB_SUBNET_1A" --allocation-id "$EIP_1A" \
  --region "$DR_REGION" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=nat-dr-1a}]" \
  --query 'NatGateway.NatGatewayId' --output text)
NAT_1B=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUB_SUBNET_1B" --allocation-id "$EIP_1B" \
  --region "$DR_REGION" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=nat-dr-1b}]" \
  --query 'NatGateway.NatGatewayId' --output text)

log "Waiting for NAT Gateways to become available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_1A" "$NAT_1B" --region "$DR_REGION"
ok "NAT Gateways ready: 1a=$NAT_1A 1b=$NAT_1B"

# ── Phase 2.9–2.11: Route Tables ─────────────────────────────────────────────
log "Creating route tables..."

# Public route table
RTB_PUBLIC=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$DR_REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-dr-public}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_PUBLIC" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" --region "$DR_REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RTB_PUBLIC" --subnet-id "$PUB_SUBNET_1A" --region "$DR_REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RTB_PUBLIC" --subnet-id "$PUB_SUBNET_1B" --region "$DR_REGION" > /dev/null

# Private app route tables (one per AZ → own NAT)
RTB_APP_1A=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$DR_REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-dr-app-1a}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_APP_1A" --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NAT_1A" --region "$DR_REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RTB_APP_1A" --subnet-id "$APP_SUBNET_1A" --region "$DR_REGION" > /dev/null

RTB_APP_1B=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$DR_REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-dr-app-1b}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_APP_1B" --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NAT_1B" --region "$DR_REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RTB_APP_1B" --subnet-id "$APP_SUBNET_1B" --region "$DR_REGION" > /dev/null

# Private DB route table (no internet)
RTB_DB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$DR_REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-dr-db}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 associate-route-table --route-table-id "$RTB_DB" --subnet-id "$DB_SUBNET_1A" --region "$DR_REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RTB_DB" --subnet-id "$DB_SUBNET_1B" --region "$DR_REGION" > /dev/null
ok "Route tables configured"

# ── Phase 2.12: DB Subnet Group ───────────────────────────────────────────────
log "Creating Aurora DB subnet group..."
aws rds create-db-subnet-group \
  --db-subnet-group-name "prod-dr-subnet-group" \
  --db-subnet-group-description "DR Aurora subnet group" \
  --subnet-ids "$DB_SUBNET_1A" "$DB_SUBNET_1B" \
  --region "$DR_REGION" \
  --tags "Key=Environment,Value=DR" > /dev/null
ok "DB subnet group created: prod-dr-subnet-group"

# ── Phase 3: Security Groups ──────────────────────────────────────────────────
log "Creating security groups..."

create_sg() {
  local name=$1 desc=$2
  aws ec2 create-security-group \
    --group-name "$name" --description "$desc" \
    --vpc-id "$VPC_ID" --region "$DR_REGION" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$name},{Key=Environment,Value=DR}]" \
    --query 'GroupId' --output text
}

SG_NGINX=$(create_sg  "sg-nginx-proxy-dr"   "DR Nginx reverse proxy")
SG_APP=$(create_sg    "sg-app-servers-dr"   "DR Node.js app servers")
SG_AURORA=$(create_sg "sg-aurora-mysql-dr"  "DR Aurora MySQL cluster")
SG_LAMBDA=$(create_sg "sg-lambda-dr"        "DR Lambda functions in VPC")
SG_ALB=$(create_sg    "sg-alb-dr"           "DR Application Load Balancer")
ok "Security groups created"

log "Configuring security group rules..."

# sg-alb-dr: internet → ALB
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" --region "$DR_REGION" \
  --ip-permissions \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" > /dev/null

# sg-nginx-proxy-dr: internet → Nginx (80/443)
aws ec2 authorize-security-group-ingress --group-id "$SG_NGINX" --region "$DR_REGION" \
  --ip-permissions \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" > /dev/null

# sg-app-servers-dr: Nginx → app (3000), ALB → app (3000), SSH from primary VPC
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" --region "$DR_REGION" \
  --ip-permissions \
  "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$SG_NGINX}]" \
  "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$SG_ALB}]" \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$PRIMARY_VPC_CIDR,Description=SSH from primary VPC}]" > /dev/null

# sg-aurora-mysql-dr: app → aurora (3306), lambda → aurora (3306)
aws ec2 authorize-security-group-ingress --group-id "$SG_AURORA" --region "$DR_REGION" \
  --ip-permissions \
  "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$SG_APP}]" \
  "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$SG_LAMBDA}]" \
  "IpProtocol=tcp,FromPort=3306,ToPort=3306,IpRanges=[{CidrIp=$PRIMARY_VPC_CIDR,Description=Primary VPC access}]" > /dev/null

# sg-lambda-dr: outbound HTTPS + DB + app
aws ec2 authorize-security-group-egress --group-id "$SG_LAMBDA" --region "$DR_REGION" \
  --ip-permissions \
  "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$SG_AURORA}]" \
  "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$SG_APP}]" > /dev/null

ok "Security group rules configured"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NETWORK SETUP COMPLETE — Save these IDs for other scripts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat <<EOF
VPC_ID="$VPC_ID"
IGW_ID="$IGW_ID"
PUB_SUBNET_1A="$PUB_SUBNET_1A"
PUB_SUBNET_1B="$PUB_SUBNET_1B"
APP_SUBNET_1A="$APP_SUBNET_1A"
APP_SUBNET_1B="$APP_SUBNET_1B"
DB_SUBNET_1A="$DB_SUBNET_1A"
DB_SUBNET_1B="$DB_SUBNET_1B"
NAT_1A="$NAT_1A"
NAT_1B="$NAT_1B"
SG_NGINX="$SG_NGINX"
SG_APP="$SG_APP"
SG_AURORA="$SG_AURORA"
SG_LAMBDA="$SG_LAMBDA"
SG_ALB="$SG_ALB"
EOF
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
ok "Next step → run: aurora-replication.sh"
