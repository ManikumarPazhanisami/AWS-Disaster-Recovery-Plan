# 🛡️ AWS Disaster Recovery Plan
### US-East-1 (Primary) → US-West-1 (DR)

![RTO](https://img.shields.io/badge/RTO-25--35%20min-blue)
![RPO](https://img.shields.io/badge/RPO-%3C%201%20min-blue)
![AWS](https://img.shields.io/badge/AWS-Multi--Region-orange)
![Status](https://img.shields.io/badge/Status-Completed-brightgreen)

---

## 👨‍💻 About This Project

This is a **personal portfolio project** documenting a full AWS Disaster Recovery (DR) implementation I designed and executed. It demonstrates real-world cloud architecture skills — multi-region failover, database replication, DNS automation, and SOC2-aligned documentation.

The plan covers a complete failover setup from **US-East-1** (primary) to **US-West-1** (DR) for a Node.js SaaS application running on Aurora MySQL, EC2, S3, Lambda, SQS, and SES.

---

## 🎯 Key Objectives

| Property | Value |
|---|---|
| **RTO (Recovery Time Objective)** | 25–35 minutes |
| **RPO (Recovery Point Objective)** | < 1 minute |
| **DR Strategy** | Warm Standby |
| **Implementation Timeline** | 6 weeks |
| **Compliance** | SOC2-aligned |

---

## 🏗️ Tech Stack

| Service | Role |
|---|---|
| **EC2** | Node.js application servers |
| **Aurora MySQL Serverless v2** | Database with Global DB cross-region replication |
| **S3** | Object storage with Cross-Region Replication (CRR) |
| **Lambda** | Serverless functions mirrored to DR region |
| **SQS** | Message queues replicated to us-west-1 |
| **SES** | Email delivery configured in DR region |
| **Route53** | Automated DNS failover with health checks |
| **CloudWatch** | Replication lag monitoring & alerting |
| **KMS** | Encryption at rest across both regions |

---

## 📂 Repository Structure

```
aws-dr-plan/
│
├── DR-Plan.html          # Full DR implementation plan (detailed doc)
├── README.md             # This file
│
├── scripts/              # CLI automation scripts
│   ├── network-setup.sh
│   ├── aurora-replication.sh
│   ├── s3-crr-setup.sh
│   └── failover-execute.sh
│
└── terraform/            # Infrastructure as Code templates
    ├── network/
    ├── database/
    └── compute/
```

---

## 📖 Implementation Phases

| Phase | Description | Duration |
|---|---|---|
| **Phase 1** | Pre-Implementation Planning & Documentation | Week 1 |
| **Phase 2** | Network Infrastructure (VPC, Subnets, NAT, IGW) | Week 2 |
| **Phase 3** | Security Groups Setup | Week 2 |
| **Phase 4** | Aurora MySQL Cross-Region Replication | Week 2–3 |
| **Phase 5** | S3 Cross-Region Replication (CRR) | Week 3 |
| **Phase 6** | EC2 AMI Copies & Launch Templates | Week 3 |
| **Phase 7** | Lambda, SQS, SES DR Setup | Week 4 |
| **Phase 8** | Route53 Failover DNS Configuration | Week 4 |
| **Phase 9** | Application Config Updates (env vars, endpoints) | Week 5 |
| **Phase 10** | DR Testing & Validation | Week 5–6 |
| **Phase 11** | Documentation & Runbook Finalization | Week 6 |

---

## 🚨 Failover Flow

```
Disaster Detected
      │
      ▼
T+0   Incident declared
      │
      ▼
T+5   Aurora Global DB promoted → us-west-1 becomes writable
      │
      ▼
T+10  EC2 instances launched from pre-copied AMIs
      │
      ▼
T+20  Route53 DNS failover propagates (TTL: 60s)
      │
      ▼
T+30  Application validated ✅ DR region is live
```

**Trigger criteria:**
- Primary region outage sustained > 5 minutes
- Aurora replication lag > 30 seconds
- Multiple Route53 health checks failing simultaneously

---

## ✅ What I Learned / Skills Demonstrated

- Designing multi-region AWS architecture for high availability
- Configuring **Aurora Global Database** for near-zero RPO replication
- Setting up **S3 Cross-Region Replication** with IAM role policies
- Automating DNS failover with **Route53 health checks**
- Writing SOC2-aligned DR documentation and runbooks
- Estimating infrastructure costs and presenting to stakeholders
- Identifying real-world gaps (Secrets Manager replication, SES sandbox, in-flight SQS messages)

---

## 🔧 Identified Gaps & Improvements

| Gap | Improvement |
|---|---|
| Secrets Manager not replicated | Enable cross-region replication for all secrets |
| SES in sandbox mode in DR region | Request production access proactively |
| SQS in-flight messages at failover | Implement DLQ + document acceptable loss policy |
| AMIs go stale between deploys | Integrate AMI copy into CI/CD pipeline |
| Aurora promotion adds ~2 min | Adjust RTO estimate to 30–37 min realistically |

---

## 💰 Estimated Cost Breakdown

| Component | Monthly Cost |
|---|---|
| Aurora Global DB (us-west-1) | ~$200/month |
| EC2 AMI storage | ~$50/month |
| NAT Gateways (2x) | ~$65/month |
| S3 CRR data transfer | ~$50/month |
| Route53 health checks | ~$6/month |
| CloudWatch, EIPs, misc | ~$130/month |
| **Total DR Overhead** | **~$501/month** |

---

## 📅 Version History

| Version | Date | Notes |
|---|---|---|
| 1.0 | April 2026 | Initial DR plan designed and documented |

---

## 🙋 About Me

I'm a DevOps / Cloud Engineer with hands-on experience designing resilient AWS infrastructure. This project reflects the kind of real-world DR planning I've worked on — from architecture decisions to cost analysis to SOC2 compliance documentation.

Feel free to connect or reach out if you have questions about the approach!

[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-blue?logo=linkedin)](https://[linkedin.com/in/mani-kumarmk/)

---

*Built with AWS, documented for the community.*
