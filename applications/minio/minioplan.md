
## 1. Objectives & Scope  
- **Primary Goal:** Provide a single, production-grade S3 endpoint today that can transparently expand to geo-distributed, active-active across two clusters.  
- **Constraints:**  
  - 6 Kubernetes nodes, each with up to 32 GiB available for MinIO volumes.  
  - Longhorn as the block-storage provider.  
  - Traefik as the ingress controller (port 443).  
  - Cloudflare Free/Pro for global DNS & proxy.  
  - ZITADEL for UI authentication; Vault available for auto-unseal.  
- **Future Expansion:** Add Cluster B with identical specs, wire it into replication and GSLB with minimal config drift.

---

## 2. Cluster Topology & Scheduling  
- **Erasure-Coding Layout:**  
  - **4 servers** × **1 volume** each → 4 × 8 GiB = 32 GiB total → 2 data + 2 parity for resilience.  
- **Pod Placement:**  
  - Allow MinIO server pods on all 6 nodes (tolerate master taints) with anti-affinity to maximize fault domains.  
- **Scale-Out Plan:**  
  - When adding nodes/storage, either increase `servers` (to 6–8) or `volumesPerServer` (to 2×16 GiB) for capacity and throughput growth without re-architecting.

---

## 3. Storage Backing  
- **Longhorn StorageClass:**  
  - Resilient, thin-provisioned block volumes.  
- **Volume Sizing:**  
  - Start with **8 GiB** per volume; enable Longhorn’s dynamic expansion for on-the-fly growth.  
- **Future “Hot” Tier:**  
  - Reserve the option to introduce a `local-ssd` StorageClass for performance-critical buckets, leaving Longhorn for bulk/archive.

---

## 4. Networking & Global Exposure  
- **Traefik Ingress:**  
  - Expose both S3 API and Console on port 443:  
    - `Host(s3.vng.bet)` → internal service port 9000  
    - `Host(console.vng.bet)` → internal port 9001  
- **Cloudflare GSLB:**  
  - Point `s3.vng.bet` and `console.vng.bet` A-records to each site’s Traefik LB IP (orange-cloud on).  
  - Use Cloudflare Health Checks + Geo-Steering/Weighted Pools for automatic fail-over and latency routing.  
- **TLS Termination:**  
  - Edge at Traefik via cert-manager (Let’s Encrypt) or Cloudflare’s Origin TLS; maintain end-to-end encryption if desired.

---

## 5. Identity & Access Management  
- **Root Credentials:**  
  - Store in Kubernetes `Secret`, enforce quarterly rotation.  
- **UI Authentication (Console):**  
  - Integrate ZITADEL as an OIDC provider in the Tenant’s OIDC config: issuer, clientID/secret, scopes.  
- **Programmatic Access:**  
  - For applications, leverage Vault’s AWS-style dynamic credentials or JWT issuance via the Vault Kubernetes auth engine.

---

## 6. Encryption at Rest & Auto-Unseal  
- **Seal Configuration:**  
  - Configure MinIO Tenant’s `seal` stanza to use your existing Vault (Transit or KMS engine).  
  - Enables seamless rolling unseal and FIPS-capable key management with zero manual intervention.

---

## 7. Multi-Site Replication Strategy  
- **Bucket Versioning:**  
  - Enable versioning on all production buckets today to simplify conflict resolution.  
- **Default Replication Policy:**  
  - Declare a GitOps-driven policy (`existing-objects, delete, delete-marker`) for every new bucket.  
- **Automation:**  
  - Script `mc alias set` + `mc replicate add` commands in your CI pipeline; on Cluster B rollout, those scripts will transparently wire up bi-directional syncing.

---

## 8. Observability & Alerts  
- **Metrics Collection:**  
  - Scrape MinIO server pods and the Operator with Prometheus.  
- **Key Alerts:**  
  - `minio_cluster_status` ≠ healthy  
  - `minio_replication_lag_seconds` > acceptable SL.  
  - PVC utilization > 80 %.  
- **Logging:**  
  - Ship S3 access and audit logs to ELK/EFK for cross-site analysis and compliance.

---

## 9. GitOps & Operational Automation  
- **Repo Layout:**  
  ```
  ├── clusters/
  │   ├── cluster-a/
  │   │   └── minio/
  │   │       ├── tenant.yaml
  │   │       └── ingressroute-s3.yaml
  │   └── cluster-b/
  │       └── minio/  (identical to cluster-a)
  └── global/
      └── replication-policies/
          └── bucket-repl.yaml
  ```  
- **Pipeline:**  
  - On merge to `main`: apply manifests to all registered clusters.  
  - Validate with smoke-tests (upload/download a test object).  
- **Cluster Onboard:**  
  - To add Cluster B, register its kube-context in your CD tool; it will install the Operator, apply the same manifests, and register its LB IP in Cloudflare.

---

## 10. Rollout Timeline & Next Steps  
| Phase          | Actions                                                                                      | Timeline     |
| -------------- | -------------------------------------------------------------------------------------------- | ------------ |
| **Day 0**      | – Install MinIO Operator in Cluster A<br>– Apply Tenant with 4×8 GiB erasure-coded pool<br>– Configure Traefik IngressRoutes | Next 1 day   |
| **Day 1–2**    | – Integrate ZITADEL OIDC<br>– Enable Vault auto-unseal<br>– Set up Prometheus scraping & alerts | Next 2 days  |
| **Week 1**     | – Finalize GitOps repo structure & CI scripts<br>– Define default replication policies        | This week    |
| **Future (Q3)**| – Onboard Cluster B via GitOps (identical spec)<br>– Configure Cloudflare pool for Cluster A/B<br>– Run `mc replicate` for buckets | Next quarter |