# NDK Sealed Secrets Runbook

## Namespaces
| Cluster | App runs here | NDK snapshots land here |
|---------|--------------|------------------------|
| A (nkp-wlc-a) | miriam-scuba-sealed | miriam-backup-sealed |
| B (nkp-wlc-b) | miriam-scuba-sealed | miriam-backup-sealed |

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

### 3. Apply NDK manifests
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

### 4. Deploy the app and seed data
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
# 1. Get the latest snapshot name on cluster B
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
kubectl get applicationsnapshots -n miriam-backup-sealed

# 2. Apply the restore (replace <SNAPSHOT-NAME> with the latest)
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

# 3. Watch restore progress
kubectl get applicationsnapshotrestore restore-failover -n miriam-scuba-sealed -w
```

---

## Failback (B → A)

> ⚠️ Before restoring, make sure no app resources exist on cluster A.
> If the helm release is still installed: `helm uninstall scuba -n miriam-scuba-sealed`

```bash
# 1. Get the latest snapshot name on cluster A
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
kubectl get applicationsnapshots -n miriam-backup-sealed

# 2. Apply the restore (replace <SNAPSHOT-NAME> with the latest)
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

# 3. Watch restore progress
kubectl get applicationsnapshotrestore restore-failback -n miriam-scuba-sealed -w
```

---

## Access the app
- Cluster A: http://10.38.48.141
- Cluster B: http://10.38.48.147

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Restore fails: "Unauthorised to access ApplicationSnapshot" | ReferenceGrant missing | `kubectl apply -f ndk-sealed/refgrant.yaml` on the target cluster |
| Restore fails: "Resources already exist" | Helm release still installed | `helm uninstall scuba -n miriam-scuba-sealed` before restoring |
| MySQL pod: "secret not found" | SealedSecrets not labelled | Ensure `app.kubernetes.io/instance: scuba` label is on SealedSecret templates |
| 404 on browser | Wrong ingress hostname after restore | Ingress uses empty host — should resolve automatically |
| "No available server" | Two wildcard ingresses conflicting | Annotate v2 ingress: `kubectl annotate ingress scuba -n miriam-scuba traefik.ingress.kubernetes.io/router.entrypoints=none` |
