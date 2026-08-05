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

## Trigger an on-demand snapshot

Use this to capture recent changes (e.g. something you just added through the
UI) instead of waiting for the hourly schedule (`js-scuba-source` /
`js-scuba-target`) to fire.

```bash
# Run against whichever cluster is currently running the app
export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf   # or nkp-wlc-b

# 1. Create the snapshot
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshot
metadata:
  name: scuba-manual-snap-1
  namespace: scuba
spec:
  source:
    applicationRef:
      name: scuba
  expiresAfter: 24h
EOF

# 2. Wait for it to be ready
kubectl get applicationsnapshot scuba-manual-snap-1 -n scuba -w

# 3. Replicate it to the other cluster (replace <REPLICATION-TARGET-NAME>:
#    repl-to-nkp-wlc-b if the app is running on A, repl-to-nkp-wlc-a if on B)
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshotReplication
metadata:
  name: scuba-manual-snap-1-repl
  namespace: scuba
spec:
  applicationSnapshotName: scuba-manual-snap-1
  replicationTargetName: <REPLICATION-TARGET-NAME>
EOF

# 4. Watch it complete
kubectl get applicationsnapshotreplication scuba-manual-snap-1-repl -n scuba -w
```

> **⚠️ Lesson learned:** out-of-band snapshots are **not** automatically
> replicated by the ProtectionPlan's schedule — the `ApplicationSnapshotReplication`
> step above is required every time. Once it completes, use
> `scuba-manual-snap-1` as `<SNAPSHOT-NAME>` in the restore steps below.

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
