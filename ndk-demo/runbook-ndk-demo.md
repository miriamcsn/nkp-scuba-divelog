# NDK Demo Runbook (Scuba Divelog — no Sealed Secrets)

## Get the repo

```bash
git clone -b scuba-no-sealed-secrets https://github.com/miriamcsn/nkp-scuba-divelog.git
cd nkp-scuba-divelog
```

## Namespaces

| Cluster | App runs here | NDK snapshots land here |
| --- | --- | --- |
| A (nkp-wlc-a) | scuba | scuba-backup |
| B (nkp-wlc-b) | scuba | scuba-backup |

## Deploy the app

```bash
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm install scuba scuba-divelog-no-sealed-secrets --namespace scuba
./scuba-divelog-no-sealed-secrets/seed-data.sh
```

---

## Failover (A → B)

> Wait for at least 1 snapshot to replicate before proceeding.
> Check: `kubectl get applicationsnapshotreplications -n scuba`

```bash
# 1. Clean up cluster A — uninstall Helm release and delete PVC
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm uninstall scuba -n scuba 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n scuba 2>/dev/null || true

# 2. Clean up cluster B — remove any leftover app resources from previous failover
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
helm uninstall scuba -n scuba 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n scuba 2>/dev/null || true

# 3. Get the latest snapshot name on cluster B
kubectl get applicationsnapshots -n scuba-backup

# 4. Apply the restore (replace <SNAPSHOT-NAME> with the latest READY-TO-USE one)
kubectl delete applicationsnapshotrestore restore-failover -n scuba 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshotRestore
metadata:
  name: restore-failover
  namespace: scuba
spec:
  applicationSnapshotName: <SNAPSHOT-NAME>
  applicationSnapshotNamespace: scuba-backup
EOF

# 5. Watch restore progress
kubectl get applicationsnapshotrestore restore-failover -n scuba -w

# 6. Force Helm to take ownership of restored resources
helm upgrade --install scuba scuba-divelog-no-sealed-secrets \
  --namespace scuba \
  --force-conflicts
```

---

## Failback (B → A)

```bash
# 1. Clean up cluster A — uninstall Helm release and delete PVC
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
helm uninstall scuba -n scuba 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n scuba 2>/dev/null || true

# 2. Get the latest snapshot name on cluster A
kubectl get applicationsnapshots -n scuba-backup

# 3. Apply the restore (replace <SNAPSHOT-NAME> with the latest READY-TO-USE one)
kubectl delete applicationsnapshotrestore restore-failback -n scuba 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshotRestore
metadata:
  name: restore-failback
  namespace: scuba
spec:
  applicationSnapshotName: <SNAPSHOT-NAME>
  applicationSnapshotNamespace: scuba-backup
EOF

# 4. Watch restore progress
kubectl get applicationsnapshotrestore restore-failback -n scuba -w

# 5. Force Helm to take ownership of restored resources
helm upgrade --install scuba scuba-divelog-no-sealed-secrets \
  --namespace scuba \
  --force-conflicts

# 6. Clean up cluster B — remove app resources now that app is back on A
export KUBECONFIG=~/.kube/manager/nkp-wlc-b-kubeconfig.conf
helm uninstall scuba -n scuba 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n scuba 2>/dev/null || true
```
