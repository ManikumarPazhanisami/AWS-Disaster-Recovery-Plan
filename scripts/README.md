# 📜 Scripts — DR Automation

These scripts automate the AWS Disaster Recovery setup and failover execution for the **US-East-1 → US-West-1** DR plan. They must be run **in order** during initial setup, and `failover-execute.sh` is reserved for actual DR events only.

---

## ⚠️ Important Warnings

- **`failover-execute.sh` is a production failover script.** Run it only when a real disaster has been declared and the Incident Commander has approved.
- All scripts use `set -euo pipefail` — they will exit immediately on any error.
- Scripts are designed to be **idempotent** where possible (safe to re-run if interrupted).
- Always run `--dry-run` on `failover-execute.sh` before an actual event to validate config.

---

## ✅ Prerequisites

Before running any script, ensure the following are in place:

| Requirement | Details |
|---|---|
| **AWS CLI** | v2.x installed and configured (`aws configure`) |
| **IAM Permissions** | EC2, RDS, S3, IAM, Route53, CloudWatch, SQS, SSM full access |
| **Primary Region** | `us-east-1` — existing VPC, Aurora cluster, S3 buckets |
| **jq** | Not required — scripts use `--output text` queries |
| **dig** | Used in `failover-execute.sh` for DNS verification (optional) |
| **curl** | Used in `failover-execute.sh` for health checks |

Verify your AWS identity before running anything:

```bash
aws sts get-caller-identity
```

---

## 📋 Execution Order

```
1. network-scripts.sh       ← Run once during DR setup
2. aurora-replication.sh    ← Run once during DR setup
3. s3-crr-setup.sh          ← Run once during DR setup
4. failover-execute.sh      ← Run ONLY during an actual DR event
```

---

## 🔧 Script Reference

### 1. `network-scripts.sh`
**Phase 2 & 3 — VPC, Subnets, NAT Gateways, Security Groups**

Sets up the complete DR network infrastructure in `us-west-1`:
- Creates VPC (`10.1.0.0/16`) with DNS support enabled
- Creates 6 subnets across 2 AZs: Public (×2), App (×2), DB (×2)
- Creates Internet Gateway and attaches to VPC
- Creates 2 NAT Gateways (one per AZ) with Elastic IPs
- Configures route tables: public → IGW, app → NAT, DB → isolated
- Creates Aurora DB subnet group (`prod-dr-subnet-group`)
- Creates 5 security groups: `sg-alb-dr`, `sg-nginx-proxy-dr`, `sg-app-servers-dr`, `sg-aurora-mysql-dr`, `sg-lambda-dr`
- Configures all SG ingress/egress rules

**Usage:**
```bash
chmod +x network-scripts.sh
./network-scripts.sh
```

**Config variables to review before running** (at top of script):

| Variable | Default | Description |
|---|---|---|
| `DR_REGION` | `us-west-1` | Target DR region |
| `VPC_CIDR` | `10.1.0.0/16` | DR VPC CIDR block |
| `PRIMARY_VPC_CIDR` | `10.0.0.0/16` | Your primary VPC CIDR (for SSH SG rule) |
| `AZ_1A` / `AZ_1B` | `us-west-1a/b` | Availability zones |

**Output:** Prints all created resource IDs at the end. **Save this output** — subsequent scripts need these IDs.

---

### 2. `aurora-replication.sh`
**Phase 4 — Aurora MySQL Cross-Region Read Replica**

Sets up Aurora MySQL Serverless v2 replication from primary to DR:
- Verifies primary cluster `ias-prod-cluster` exists in `us-east-1`
- Creates a KMS encryption key in `us-west-1` with alias `alias/aurora-dr`
- Verifies the DB subnet group created by `network-scripts.sh`
- Creates a cross-region read replica cluster (`ias-prod-cluster-dr`) in `us-west-1`
- Adds a Serverless v2 instance (`db.serverless`, 1–8 ACUs)
- Waits up to 45 minutes for the cluster to become available
- Creates CloudWatch alarms for replication lag (>5s) and CPU (>80%)
- Runs a replication lag check via CloudWatch metrics

**Usage:**
```bash
# Run network-scripts.sh first, then:
chmod +x aurora-replication.sh
./aurora-replication.sh
```

**Config variables to update before running:**

| Variable | Default | Description |
|---|---|---|
| `PRIMARY_CLUSTER_ID` | `ias-prod-cluster` | Your primary Aurora cluster ID |
| `DR_CLUSTER_ID` | `ias-prod-cluster-dr` | Name for the DR cluster |
| `DR_INSTANCE_ID` | `ias-prod-instance-1-dr` | Name for the DR instance |
| `SG_AURORA` | `sg-aurora-mysql-dr` | Aurora SG (auto-resolved by name) |
| `SNS_ALARM_ARN` | *(empty)* | Optional SNS topic for CloudWatch alerts |

**Expected duration:** 20–45 minutes (Aurora cluster creation)

---

### 3. `s3-crr-setup.sh`
**Phase 5 — S3 Cross-Region Replication**

Configures S3 Cross-Region Replication (CRR) from `us-east-1` to `us-west-1`:
- Enables versioning on all source buckets (required for CRR)
- Creates corresponding DR buckets with `-uswest1` suffix
- Enables versioning and blocks public access on all DR buckets
- Creates IAM role `s3-crr-role-dr` with least-privilege replication permissions
- Configures replication rules with **S3 Replication Time Control (RTC)** — 15-minute SLA
- Runs a live replication test by uploading a test file and verifying it appears in the DR bucket

**Usage:**
```bash
# Run network-scripts.sh first, then:
chmod +x s3-crr-setup.sh
./s3-crr-setup.sh
```

**Config to update before running:**

| Variable | Default | Description |
|---|---|---|
| `BUCKET_BASES` | `mybucket-prod` | Array of bucket base names to replicate |

**Bucket naming convention expected:**
```
Source (us-east-1):  mybucket-prod-useast1
DR     (us-west-1):  mybucket-prod-uswest1  ← created automatically
```

Add all your production buckets to the `BUCKET_BASES` array before running.

---

### 4. `failover-execute.sh`
**DR Execution — US-East-1 → US-West-1 Failover**

> ⚠️ **Production failover script. Do not run this during drills without `--dry-run`.**

Executes the complete DR failover sequence with checkpoints requiring operator confirmation at each critical step:

| Step | Action | Est. Time |
|---|---|---|
| Preflight | Verify AWS CLI, DR cluster, launch templates | ~1 min |
| Step 4 | Check Aurora replication lag | ~1 min |
| Step 7 | Promote Aurora DR replica to primary | ~10 min |
| Step 9 | Update Route53 CNAME for database | ~1 min |
| Step 10 | Launch EC2 app servers from launch templates | ~3 min |
| Step 11–12 | Health check app instances via SSM | ~2 min |
| Step 13 | Launch Nginx proxy + associate EIP | ~2 min |
| Step 15 | Update Route53 A record for application | ~1 min |
| Step 16 | Wait for DNS propagation (TTL=60s) | ~3 min |
| Step 17 | End-to-end health check via public DNS | ~1 min |
| Step 18 | Verify SQS DR queues exist | ~1 min |

**Usage:**
```bash
# Dry run first — always
./failover-execute.sh --dry-run

# Actual failover (coordinate with Incident Commander)
./failover-execute.sh
```

**Config variables to update before use** (mandatory — script will fail or behave incorrectly if left as defaults):

| Variable | Description |
|---|---|
| `DR_CLUSTER_ID` | DR Aurora cluster ID |
| `DR_DB_ENDPOINT` | Full RDS endpoint for DR cluster |
| `DB_CNAME` | Route53 CNAME for database |
| `API_CNAME` | Route53 record for application |
| `HOSTED_ZONE_ID` | Route53 hosted zone ID |
| `APP_LAUNCH_TEMPLATE` | EC2 launch template name in `us-west-1` |
| `NGINX_LAUNCH_TEMPLATE` | Nginx EC2 launch template name |
| `NGINX_EIP_ALLOCATION` | Pre-allocated EIP allocation ID |
| `SQS_QUEUE_MAP` | Map of primary → DR queue names |

**Failover log:** Written to `/tmp/dr-failover-<timestamp>.log` automatically.

---

## 🧪 Testing Without a Real Disaster

Use `--dry-run` on the failover script regularly — ideally quarterly — to validate the config is up to date:

```bash
./failover-execute.sh --dry-run
```

This prints every action that *would* be taken without making any AWS changes.

---

## 🔁 After Failover — Failback

Once the primary region (`us-east-1`) is restored, a manual failback process is required:
1. Re-establish Aurora replication from `us-west-1` back to `us-east-1`
2. Reverse Route53 DNS records
3. Re-run `network-scripts.sh` and `aurora-replication.sh` in reverse direction
4. Document incident timeline and update runbook

Refer to `docs/DR-Plan.html` for the full failback runbook.
