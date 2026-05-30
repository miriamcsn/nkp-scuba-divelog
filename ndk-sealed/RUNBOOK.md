# NDK Sealed Secrets Runbook

## Namespaces
| Cluster | App runs here | NDK snapshots land here |
|---------|--------------|------------------------|
| A (nkp-wlc-a) | miriam-scuba-sealed | miriam-backup-sealed |
| B (nkp-wlc-b) | miriam-scuba-sealed | miriam-backup-sealed |

## Access
- **URL:** http://scubadivelog.online (DNS managed automatically by ExternalDNS)
- After failover → ExternalDNS on cluster B updates DNS to `10.38.48.147` automatically
- After failback → ExternalDNS on cluster A updates DNS to `10.38.48.141` automatically
- ⚠️ `scubadivelog.online` resolves to a private IP — must be on the same network as the clusters

---

## Initial Setup (one-time)

### 1. Create namespaces on both clusters
```bash
# Cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
kubectl create namespace miriam-scuba-sealed
kubectl create namespace miriam-backup-sealed

# Cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl create namespace miriam-scuba-sealed
kubectl create namespace miriam-backup-sealed
```

### 2. Install Sealed Secrets controller on BOTH clusters
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

# Cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace miriam-scuba-sealed --version 2.17.2

# Cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace miriam-scuba-sealed --version 2.17.2
```

### 3. Apply sealed secrets (Cloudflare token + app secrets)
```bash
# Cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
kubectl apply -f ndk-sealed/sealed-cloudflare-token.yaml
kubectl apply -f ndk-sealed/sealed-mysql-secret.yaml
kubectl apply -f ndk-sealed/sealed-app-db-secret.yaml

# Cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl apply -f ndk-sealed/sealed-cloudflare-token.yaml
kubectl apply -f ndk-sealed/sealed-mysql-secret.yaml
kubectl apply -f ndk-sealed/sealed-app-db-secret.yaml
```

### 4. Install ExternalDNS on BOTH clusters
```bash
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update

# Cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm install external-dns external-dns/external-dns \
  --namespace miriam-scuba-sealed \
  --set provider.name=cloudflare \
  --set "cloudflare.proxied=false" \
  --set "domainFilters={scubadivelog.online}" \
  --set "sources={ingress}" \
  --set "policy=sync" \
  --set "txtOwnerId=nkp-wlc-a" \
  --set "env[0].name=CF_API_TOKEN" \
  --set "env[0].valueFrom.secretKeyRef.name=cloudflare-api-token" \
  --set "env[0].valueFrom.secretKeyRef.key=cloudflare_api_token"

# Cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
helm install external-dns external-dns/external-dns \
  --namespace miriam-scuba-sealed \
  --set provider.name=cloudflare \
  --set "cloudflare.proxied=false" \
  --set "domainFilters={scubadivelog.online}" \
  --set "sources={ingress}" \
  --set "policy=sync" \
  --set "txtOwnerId=nkp-wlc-b" \
  --set "env[0].name=CF_API_TOKEN" \
  --set "env[0].valueFrom.secretKeyRef.name=cloudflare-api-token" \
  --set "env[0].valueFrom.secretKeyRef.key=cloudflare_api_token"
```

### 5. Apply NDK manifests
```bash
# Cluster A — source
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
kubectl apply -f ndk-sealed/source-ndk.yaml
kubectl apply -f ndk-sealed/refgrant.yaml   # ⚠️ required on BOTH clusters

# Cluster B — target
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl apply -f ndk-sealed/target-ndk.yaml
kubectl apply -f ndk-sealed/refgrant.yaml   # ⚠️ required on BOTH clusters
```

> **⚠️ Lesson learned:** `refgrant.yaml` must be applied on **both** clusters.
> Without it on cluster A, failback will fail with "Unauthorised to access the ApplicationSnapshot".

### 6. Deploy the app and seed data
```bash
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm install scuba deploy/charts/scuba-divelog --namespace miriam-scuba-sealed
./scripts/seed-scuba-v3.sh
```

---

## Failover (A → B)

> Wait for at least 1 snapshot to replicate before proceeding.
> Check: `kubectl get applicationsnapshotreplications -n miriam-scuba-sealed`

```bash
# 1. Clean up cluster A — uninstall Helm release and delete PVC
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm uninstall scuba -n miriam-scuba-sealed 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n miriam-scuba-sealed 2>/dev/null || true

# 2. Clean up cluster B — remove any leftover resources from previous failover
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
helm uninstall scuba -n miriam-scuba-sealed 2>/dev/null || true
kubectl delete deploy,statefulset,svc,ingress,configmap,pvc,sealedsecret \
  -n miriam-scuba-sealed -l app.kubernetes.io/instance=scuba 2>/dev/null || true

# 3. Get the latest snapshot name on cluster B
kubectl get applicationsnapshots -n miriam-backup-sealed

# 4. Apply the restore (replace <SNAPSHOT-NAME> with the latest READY-TO-USE one)
kubectl delete applicationsnapshotrestore restore-failover -n miriam-scuba-sealed 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshotRestore
metadata:
  name: restore-failover
  namespace: miriam-scuba-sealed
spec:
  applicationSnapshotName: <SNAPSHOT-NAME>
  applicationSnapshotNamespace: miriam-backup-sealed
EOF

# 5. Watch restore progress
kubectl get applicationsnapshotrestore restore-failover -n miriam-scuba-sealed -w

# 6. Force Helm to take ownership of restored resources
helm upgrade --install scuba deploy/charts/scuba-divelog \
  --namespace miriam-scuba-sealed \
  --force-conflicts

# 7. Verify DNS updated automatically
dig +short scubadivelog.online @8.8.8.8   # should return 10.38.48.147
```

---

## Failback (B → A)

```bash
# 1. Clean up cluster A — uninstall Helm release and delete PVC
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm uninstall scuba -n miriam-scuba-sealed 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n miriam-scuba-sealed 2>/dev/null || true

# 2. Get the latest snapshot name on cluster A
kubectl get applicationsnapshots -n miriam-backup-sealed

# 3. Apply the restore (replace <SNAPSHOT-NAME> with the latest READY-TO-USE one)
kubectl delete applicationsnapshotrestore restore-failback -n miriam-scuba-sealed 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshotRestore
metadata:
  name: restore-failback
  namespace: miriam-scuba-sealed
spec:
  applicationSnapshotName: <SNAPSHOT-NAME>
  applicationSnapshotNamespace: miriam-backup-sealed
EOF

# 4. Watch restore progress
kubectl get applicationsnapshotrestore restore-failback -n miriam-scuba-sealed -w

# 5. Force Helm to take ownership of restored resources
helm upgrade --install scuba deploy/charts/scuba-divelog \
  --namespace miriam-scuba-sealed \
  --force-conflicts

# 6. Clean up cluster B — remove resources now that app is back on A
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
helm uninstall scuba -n miriam-scuba-sealed 2>/dev/null || true
kubectl delete deploy,statefulset,svc,ingress,configmap,pvc,sealedsecret \
  -n miriam-scuba-sealed -l app.kubernetes.io/instance=scuba 2>/dev/null || true

# 7. Verify DNS updated automatically
dig +short scubadivelog.online @8.8.8.8   # should return 10.38.48.141
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Restore fails: "Unauthorised to access ApplicationSnapshot" | ReferenceGrant missing | `kubectl apply -f ndk-sealed/refgrant.yaml` on the target cluster |
| Restore fails: "Resources already exist" | Helm release still installed | `helm uninstall scuba -n miriam-scuba-sealed` before restoring |
| MySQL pod: "secret not found" | SealedSecrets not labelled | Ensure `app.kubernetes.io/instance: scuba` label is on SealedSecret templates |
| ExternalDNS not updating DNS | Wrong A record exists in Cloudflare | Delete existing A record manually, ExternalDNS will recreate it |
| DNS resolves to Cloudflare IPs | Proxying enabled | Set DNS-only (grey cloud) on the A record in Cloudflare |
| "No available server" | Two wildcard ingresses conflicting | Annotate v2 ingress: `kubectl annotate ingress scuba -n miriam-scuba traefik.ingress.kubernetes.io/router.entrypoints=none` |
