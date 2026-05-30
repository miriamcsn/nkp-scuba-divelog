# NDK Sync Replication Runbook (v4)

## Prerequisites — confirm with Nutanix admin BEFORE starting

- [ ] Metro Availability is configured between the two Prism Elements backing nkp-wlc-a and nkp-wlc-b
- [ ] A Metro-enabled storage container exists on both sites
- [ ] `storageclass-sync.yaml` has been updated with the correct `storageContainer` and `replicationType` parameters

Ask your admin: *"Is Metro Availability configured between the Prism Elements backing nkp-wlc-a and nkp-wlc-b?"*

---

## Key differences from v3 (async)

| | v3 (Async) | v4 (Sync) |
|--|-----------|-----------|
| RPO | ~60 min | 0 |
| RTO | Minutes | Seconds |
| NDK type | `protectionType: async` | `protectionType: sync` |
| Scheduler | Required (60 min interval) | Not needed |
| Storage class | `nutanix-volume` | `nutanix-volume-sync` (Metro) |
| Failover | Restore from snapshot | Promote replica instantly |

---

## Namespaces

| Cluster | App runs here | NDK data lands here |
|---------|--------------|----------------------|
| A (nkp-wlc-a) | miriam-scuba-sync | miriam-backup-sync |
| B (nkp-wlc-b) | miriam-scuba-sync | miriam-backup-sync |

---

## Initial Setup (one-time)

### 1. Create namespaces on both clusters
```bash
# Cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
kubectl create namespace miriam-scuba-sync
kubectl create namespace miriam-backup-sync

# Cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl create namespace miriam-scuba-sync
kubectl create namespace miriam-backup-sync
```

### 2. Apply Metro storage class on BOTH clusters
```bash
# ⚠️ Edit storageclass-sync.yaml first — fill in storageContainer and replicationType
# Cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
kubectl apply -f ndk-sync/storageclass-sync.yaml

# Cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl apply -f ndk-sync/storageclass-sync.yaml
```

### 3. Install Sealed Secrets + ExternalDNS (same as v3)
```bash
# Follow steps 2 and 4 from ndk-sealed/RUNBOOK.md
# targeting miriam-scuba-sync namespace instead
```

### 4. Apply NDK manifests
```bash
# Cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
kubectl apply -f ndk-sync/source-ndk.yaml
kubectl apply -f ndk-sync/refgrant.yaml   # ⚠️ required on BOTH clusters

# Cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl apply -f ndk-sync/target-ndk.yaml
kubectl apply -f ndk-sync/refgrant.yaml   # ⚠️ required on BOTH clusters
```

### 5. Deploy the app with sync storage class
```bash
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm install scuba deploy/charts/scuba-divelog \
  --namespace miriam-scuba-sync \
  -f ndk-sync/values-override.yaml
./scripts/seed-scuba-v3.sh
```

---

## Failover (A → B)

With sync replication, data is already on cluster B — no restore needed.

```bash
# 1. Clean up cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm uninstall scuba -n miriam-scuba-sync 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n miriam-scuba-sync 2>/dev/null || true

# 2. Get the latest sync snapshot on cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl get applicationsnapshots -n miriam-backup-sync

# 3. Delete old restore object if exists, then restore
kubectl delete applicationsnapshotrestore restore-failover -n miriam-scuba-sync 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshotRestore
metadata:
  name: restore-failover
  namespace: miriam-scuba-sync
spec:
  applicationSnapshotName: <SNAPSHOT-NAME>
  applicationSnapshotNamespace: miriam-backup-sync
EOF

# 4. Watch restore progress
kubectl get applicationsnapshotrestore restore-failover -n miriam-scuba-sync -w

# 5. Force Helm to take ownership
helm upgrade --install scuba deploy/charts/scuba-divelog \
  --namespace miriam-scuba-sync \
  -f ndk-sync/values-override.yaml \
  --force-conflicts

# 6. Patch Traefik TLS annotations
kubectl annotate ingress scuba -n miriam-scuba-sync \
  "traefik.ingress.kubernetes.io/router.tls=true" \
  "traefik.ingress.kubernetes.io/router.entrypoints=websecure" \
  --overwrite

# 7. DNS handoff
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
kubectl scale deployment external-dns --replicas=0 -n miriam-scuba-sync
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl scale deployment external-dns --replicas=1 -n miriam-scuba-sync
# ⚠️ Delete A record in Cloudflare — ExternalDNS recreates it pointing to 10.38.48.147

# 8. Verify
dig +short scubadivelog.online @8.8.8.8   # should return 10.38.48.147
```

---

## Failback (B → A)

```bash
# 1. Clean up cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm uninstall scuba -n miriam-scuba-sync 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n miriam-scuba-sync 2>/dev/null || true

# 2. Get the latest sync snapshot on cluster A
kubectl get applicationsnapshots -n miriam-backup-sync

# 3. Delete old restore object if exists, then restore
kubectl delete applicationsnapshotrestore restore-failback -n miriam-scuba-sync 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshotRestore
metadata:
  name: restore-failback
  namespace: miriam-scuba-sync
spec:
  applicationSnapshotName: <SNAPSHOT-NAME>
  applicationSnapshotNamespace: miriam-backup-sync
EOF

# 4. Watch restore progress
kubectl get applicationsnapshotrestore restore-failback -n miriam-scuba-sync -w

# 5. Force Helm to take ownership
helm upgrade --install scuba deploy/charts/scuba-divelog \
  --namespace miriam-scuba-sync \
  -f ndk-sync/values-override.yaml \
  --force-conflicts

# 6. Patch Traefik TLS annotations
kubectl annotate ingress scuba -n miriam-scuba-sync \
  "traefik.ingress.kubernetes.io/router.tls=true" \
  "traefik.ingress.kubernetes.io/router.entrypoints=websecure" \
  --overwrite

# 7. DNS handoff
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl scale deployment external-dns --replicas=0 -n miriam-scuba-sync
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
kubectl scale deployment external-dns --replicas=1 -n miriam-scuba-sync
# ⚠️ Delete A record in Cloudflare — ExternalDNS recreates it pointing to 10.38.48.141

# 8. Clean up cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
helm uninstall scuba -n miriam-scuba-sync 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n miriam-scuba-sync 2>/dev/null || true

# 9. Verify
dig +short scubadivelog.online @8.8.8.8   # should return 10.38.48.141
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| ProtectionPlan degraded | Metro Availability not configured | Confirm with Nutanix admin |
| PVC stuck in Pending | Wrong storage class / Metro not enabled | Check `storageclass-sync.yaml` parameters with admin |
| All other issues | Same as v3 | See `ndk-sealed/RUNBOOK.md` troubleshooting table |
