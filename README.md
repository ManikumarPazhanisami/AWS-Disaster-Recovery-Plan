# 🛡️ AWS Disaster Recovery Plan
### US-East-1 (Primary) → US-West-1 (DR)

![DR Status](https://img.shields.io/badge/DR%20Status-Active-brightgreen)
![RTO](https://img.shields.io/badge/RTO-25--35%20min-blue)
![RPO](https://img.shields.io/badge/RPO-%3C%201%20min-blue)
![SOC2](https://img.shields.io/badge/SOC2-Compliant-purple)
![Version](https://img.shields.io/badge/Version-1.0-orange)

---

## 📋 Overview

This repository contains the complete **Disaster Recovery (DR) Implementation Plan** for our SaaS infrastructure on AWS. It covers failover from the primary region **US-East-1** to the DR region **US-West-1 (N. California)**.

| Property | Value |
|---|---|
| **Organization** | Your SaaS Company |
| **Primary Region** | US-East-1 (N. Virginia) |
| **DR Region** | US-West-1 (N. California) |
| **RTO** | 25–35 minutes |
| **RPO** | < 1 minute |
| **Monthly DR Cost** | ~$501/month |
| **Implementation Timeline** | 6 weeks |
| **Document Version** | 1.0 |
| **Last Updated** | January 2026 |

---

## 🏗️ Infrastructure Stack

| Service | Usage |
|---|---|
| **EC2** | Node.js application servers |
| **Aurora MySQL Serverless v2** | Primary database with cross-region replication |
| **S3** | Object storage with Cross-Region Replication (CRR) |
| **Lambda** | Serverless functions |
| **SQS** | Message queuing |
| **SES** | Email delivery |
| **Route53** | DNS failover automation |
| **CloudWatch** | Monitoring & alerting |

---

## 📂 Repository Structure

```
dr-plan/
│
├── DR-Plan.html          # Full DR implementation plan (rendered doc)
├── README.md             # This file
│
├── scripts/              # (Recommended) CLI automation scripts
│   ├── network-setup.sh
│   ├── aurora-replication.sh
│   ├── s3-crr-setup.sh
│   └── failover-execute.sh
│
└── terraform/            # (Recommended) Infrastructure as Code
    ├── network/
    ├── database/
    └── compute/
```

---

## 📖 DR Plan Phases

| Phase | Description | Duration |
|---|---|---|
| **Phase 1** | Pre-Implementation Planning | Week 1 |
| **Phase 2** | Network Infrastructure Setup (VPC, Subnets, NAT) | Week 2 |
| **Phase 3** | Security Groups Setup | Week 2 |
| **Phase 4** | Aurora MySQL Cross-Region Replication | Week 2–3 |
| **Phase 5** | S3 Cross-Region Replication | Week 3 |
| **Phase 6** | EC2 AMI & Launch Templates | Week 3 |
| **Phase 7** | Lambda, SQS, SES Setup | Week 4 |
| **Phase 8** | Route53 Failover Configuration | Week 4 |
| **Phase 9** | Application Configuration Updates | Week 5 |
| **Phase 10** | DR Testing & Validation | Week 5–6 |
| **Phase 11** | Documentation & Training | Week 6 |

---

## 🚨 Failover Quick Reference

> **For full step-by-step instructions, refer to the [DR Plan](./DR-Plan.html)**

### Trigger Criteria
- Primary region outage > 5 minutes
- Aurora replication lag > 30 seconds sustained
- Multiple service health checks failing

### Estimated Failover Timeline

| Step | Action | Time |
|---|---|---|
| T+0 | Incident declared, team alerted | 0 min |
| T+5 | Aurora Global DB promoted in us-west-1 | 5–7 min |
| T+10 | EC2 instances launched from AMI | 10–15 min |
| T+20 | Route53 DNS failover propagated | 20–25 min |
| T+30 | Application validated in DR region | 25–35 min |

---

## ✅ SOC2 Compliance Checklist

- [x] Documented DR Plan
- [x] RTO/RPO Objectives defined and approved
- [x] Quarterly DR drills scheduled
- [x] Annual full DR test planned
- [x] Aurora cross-region replication active
- [x] S3 CRR configured
- [x] Route53 automated DNS failover
- [x] Infrastructure as Code (Terraform)
- [x] CloudWatch monitoring & alerting
- [x] KMS encryption at rest
- [x] Post-incident review process documented

---

## 💰 Cost Summary

| Component | Monthly Cost |
|---|---|
| Aurora Read Replica (us-west-1) | ~$200/month |
| EC2 (stopped, AMI storage) | ~$50/month |
| NAT Gateways (2x) | ~$65/month |
| S3 CRR data transfer | ~$50/month |
| Route53 health checks | ~$6/month |
| Misc (CloudWatch, EIPs, etc.) | ~$130/month |
| **Total Additional Cost** | **~$501/month** |

---

## 🔧 Known Gaps & Recommendations

| Gap | Recommendation |
|---|---|
| Secrets Manager not replicated | Enable automatic replication to us-west-1 |
| SES sandbox in DR region | Request production access in us-west-1 proactively |
| SQS in-flight messages | Document acceptable loss policy; consider DLQ strategy |
| Stale AMIs after deploys | Add DR AMI copy step to CI/CD pipeline |
| Aurora promotion time (~2 min) | Factor into RTO; update to 30–37 min range |

---

## 📞 Escalation Path

1. On-call Engineer detects issue
2. Incident Commander activated
3. Technical teams engaged per severity
4. Management notified if RTO is exceeded

> Contact details are maintained in the internal runbook (restricted access).

---

## 📅 Document Control

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0 | Jan 28, 2026 | DevOps Team | Initial DR plan |

**Next Review Date**: April 28, 2026 (quarterly)

---

## ⚠️ Confidentiality Notice

This DR Plan is **confidential** and intended for authorized personnel only.  
Do not share outside the organization without prior approval from the DevOps Lead.

---

*For questions or updates, contact the DevOps Team.*
