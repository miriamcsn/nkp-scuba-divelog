# Velero on NKP Ultimate — Nutanix Objects — Setup Runbook

## Architecture

```
Nutanix Objects
  └── ONE bucket (e.g. velero-poc)  ← shared by both clusters
        ├── Cluster A writes backups here
        └── Cluster B reads backups from here
```

**Critical rule**: both clusters must point to the **same** Objects bucket at the **same** endpoint with the **same** credentials. This is the only pattern that works reliably.

---

## Pre-requisites

- NKP Ultimate installed, management cluster up
- Two workload clusters provisioned (Cluster A, Cluster B)
- `kubectl` access to both clusters
- Prism Central access (Objects management)
- `velero` CLI installed on your bastion

```bash
curl -L https://github.com/vmware-tanzu/velero/releases/download/v1.17.0/velero-v1.17.0-linux-amd64.tar.gz | tar xz
sudo mv velero-v1.17.0-linux-amd64/velero /usr/local/bin/
velero version --client-only
# Expected:
# Client:
#   Version: v1.17.0
```

---

## Phase 1 — Nutanix Objects setup (Prism Central)

**What this phase does**: Before Velero can store backups, it needs somewhere to put them. Nutanix Objects is an S3-compatible object storage service — think of it as a shared network drive accessible over HTTPS. In this phase, you create the storage bucket and generate API credentials so Velero can authenticate to it.

**1.1 — Create the bucket**

Prism Central → Objects → select your Objects Store → Buckets → Create Bucket

- Name: `velero-poc`
- Versioning: enable it
- Leave all other defaults

**1.2 — Generate access keys**

Prism Central → Objects → Access Keys → Add People → select the Objects user → Generate Keys

You will get two values. **Copy them immediately — the secret key is shown only once.**

| Value | What it is |
|-------|-----------|
| Access Key | A public identifier, like a username for the API |
| Secret Key | A private password used to sign and authenticate API requests |

**Where to save them**: for this PoC, paste them into your password manager or a secure note right now. In production, store them in a secrets manager (HashiCorp Vault, NKP Secret Store, etc.). You will use them in Phase 4.

**1.3 — Record the Objects Store endpoint**

In Prism Central → Objects → your Objects Store, find the IP address. The API port is always `8085`. Note it down alongside your keys:

```
Objects endpoint:  https://<objects-store-ip>:8085
Access Key:        <save here>
Secret Key:        <save here>
```

You will need these three values in Phases 4 and 5.

---

## Phase 2 — Enable Velero on both clusters

**What this phase does**: NKP Ultimate ships with Velero as a built-in platform application, but it is not enabled by default. This phase turns it on for both clusters so NKP deploys and manages the Velero pods automatically via Flux.

**2.1 — Enable via NKP UI**

1. Go to **Clusters** → select **Cluster A**
2. Go to the **Applications** tab
3. Find **Velero** → click **Enable**
4. Repeat for **Cluster B**

Wait ~2 minutes, then verify on each cluster:

```bash
kubectl get pods -A | grep velero
# Expected: one velero-* pod per cluster in STATUS Running
# Example:
# nkp-flux-provisioned-abcde-12345   velero-7d9f8b6c4-xkpqz   1/1   Running   0   2m
```

**2.2 — What if pods don't come up?**

```bash
# Check if the HelmRelease reconciled successfully
kubectl -n kommander-flux get helmrelease velero
# Expected:
# NAME     READY   STATUS                              AGE
# velero   True    Release reconciliation succeeded    5m

# If READY is False, inspect the error:
kubectl -n kommander-flux describe helmrelease velero | grep -A 20 "Conditions:"
# Look for a message explaining why it failed (e.g. chart not found, image pull error)

# Check the Flux controller logs for more detail:
kubectl -n kommander-flux logs deployment/helm-controller | tail -30
# Expected: lines confirming "reconciliation succeeded"
# Error to watch for: "install retries exhausted" → usually means chart source is not synced yet;
# wait 2 minutes and re-check, or inspect the HelmRepository source status
```

---

## Phase 3 — Find the Velero namespace

**What this phase does**: NKP places each platform application in a dynamically named namespace containing a unique hash. Before running any Velero commands, you need the exact namespace name. This phase finds it and stores it in a shell variable so you don't have to type it in every command.

**Do this on both clusters.**

```bash
kubectl get namespace | grep nkp-flux-provisioned
# Expected:
# nkp-flux-provisioned-phvwv-jjxpb   Active   15m
# (your hash will be different)
```

Now store it as an environment variable in your current shell session:

```bash
export VELERO_NS="nkp-flux-provisioned-<your-hash>"

# Confirm it was set:
echo $VELERO_NS
# Expected: nkp-flux-provisioned-<your-hash>
```

> This variable lives in your current terminal session only. If you open a new terminal, run `export VELERO_NS="..."` again. To make it permanent, add that line to your `~/.bashrc`.

Confirm Velero is running in that namespace:

```bash
kubectl -n $VELERO_NS get pods -l app.kubernetes.io/name=velero
# Expected:
# NAME                      READY   STATUS    RESTARTS   AGE
# velero-7d9f8b6c4-xkpqz   1/1     Running   0          5m
```

---

## Phase 4 — Configure credentials on both clusters

**What this phase does**: Velero needs to authenticate to Nutanix Objects every time it uploads or downloads a backup. In NKP, credentials are injected into the Velero pod as environment variables via a Kubernetes secret called `dkp-velero`. We update that secret with the Objects keys from Phase 1.

**Why do the variable names say "aws"?**

Nutanix Objects implements the **S3 protocol** — the same storage API originally designed by Amazon S3. Velero's storage plugin was written for AWS S3, and since Nutanix Objects speaks the identical protocol, the same plugin and variable names are reused. The `aws_` prefix has nothing to do with Amazon — it is the name of the wire protocol. Many non-AWS storage systems (Nutanix Objects, MinIO, Ceph) are S3-compatible and use the same variable names.

**Is patching the `dkp-velero` secret directly a production best practice?**

No — and it is important to be transparent about this. Directly patching `dkp-velero` is not the officially documented method. The documented production approach is:

1. Create **your own** credential secret in the Velero namespace
2. Reference it via the Velero `AppDeployment` using the `extraSecretRef` field in a config override

This approach survives Flux reconciliation and platform upgrades. Direct patching of `dkp-velero` risks being overwritten when NKP reconciles the platform application.

**For this PoC, both paths produce the same working result.** Use 4-A for speed; use 4-B if the customer asks about production readiness.

---

### Phase 4-A — Quick path (PoC / demo)

Patch `dkp-velero` directly. **Do this on Cluster A AND Cluster B with the same values.**

```bash
kubectl -n $VELERO_NS create secret generic dkp-velero \
  --from-literal=AWS_ACCESS_KEY_ID=<access-key-from-phase-1> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret-key-from-phase-1> \
  --dry-run=client -o yaml | kubectl apply -f -
# Expected: secret/dkp-velero configured
```

```bash
kubectl -n $VELERO_NS rollout restart deployment velero
# Expected: deployment.apps/velero restarted

kubectl -n $VELERO_NS rollout status deployment velero
# Expected: deployment "velero" successfully rolled out
```

---

### Phase 4-B — Production path

**Do this on Cluster A AND Cluster B with the same values.**

```bash
# Step 1: Create a user-managed credential secret
kubectl -n $VELERO_NS create secret generic velero-objects-creds \
  --from-literal=AWS_ACCESS_KEY_ID=<access-key-from-phase-1> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret-key-from-phase-1>
# Expected: secret/velero-objects-creds created
```

```bash
# Step 2: Find the workspace namespace
kubectl get namespace | grep workspace
# Expected: something like "kommander-default-workspace   Active   2h"
# Note it — you will use it in the next two steps
```

```bash
# Step 3: Create a ConfigMap that overrides Velero's extraSecretRef
cat <<EOF | kubectl -n <WORKSPACE_NS> apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: velero-overrides
data:
  values.yaml: |
    credentials:
      extraSecretRef: velero-objects-creds
EOF
# Expected: configmap/velero-overrides created
```

```bash
# Step 4: Patch the Velero AppDeployment to use the override
kubectl -n <WORKSPACE_NS> patch appdeployment velero --type="merge" \
  -p '{"spec":{"configOverrides":{"name":"velero-overrides"}}}'
# Expected: appdeployment.apps.kommander.mesosphere.io/velero patched
```

Flux reconciles the HelmRelease automatically. Wait ~30 seconds, then verify:

```bash
kubectl -n $VELERO_NS rollout status deployment velero
# Expected: deployment "velero" successfully rolled out
```

---

## Phase 5 — Configure the BackupStorageLocation on both clusters

**What this phase does**: A **BackupStorageLocation (BSL)** is a Kubernetes object that tells Velero *where* to store backups — which bucket, at which endpoint, and how to connect to it. Think of it as an address card: "backups go to this bucket, at this URL, using this protocol."

NKP automatically creates a BSL named `default` when Velero is enabled. We update that existing BSL to point at your Nutanix Objects bucket.

**Why update the existing `default` BSL instead of creating a new one?**

Velero uses the BSL named `default` automatically when no `storageLocation` is specified in a Backup manifest. If you create a second BSL with a different name, every Backup and Restore manifest would need to explicitly reference it — adding friction. Updating the existing `default` BSL is simpler, keeps a single source of truth, and means your backup manifests stay clean.

**Do this on Cluster A AND Cluster B with the same values.**

```bash
kubectl -n $VELERO_NS patch backupstoragelocation default \
  --type='merge' \
  -p='{
    "spec": {
      "provider": "aws",
      "objectStorage": {
        "bucket": "velero-poc"
      },
      "config": {
        "region": "dkp-object-store",
        "s3ForcePathStyle": "true",
        "s3Url": "https://<objects-store-ip>:8085",
        "insecureSkipTLSVerify": "true",
        "checksumAlgorithm": ""
      }
    }
  }'
# Expected: backupstoragelocation.velero.io/default patched
```

> `s3ForcePathStyle: "true"` is required because Nutanix Objects uses path-style URLs (`https://host/bucket/key`), not virtual-hosted-style (`https://bucket.host/key`). `checksumAlgorithm: ""` disables a checksum feature that Nutanix Objects does not support.

---

## Phase 6 — Enable node-agent on both clusters *(skip if stateless workloads only)*

**What this phase does**: By default, Velero backs up Kubernetes resource definitions (Deployments, Services, ConfigMaps, etc.) but **not the actual data inside Persistent Volumes (PVCs)**. The node-agent is a DaemonSet that runs on every node and uses a tool called Kopia to snapshot the volume data and upload it to the Objects bucket. You need this for any application that has a database or persistent storage.

> **Stateless workloads only?** If your application has no PVCs, skip this entire phase.

In NKP, node-agent is controlled through the Velero Helm chart configuration — you enable it via a ConfigMap.

**6.1 — Find the ConfigMap that controls Velero's Helm values**

```bash
kubectl -n $VELERO_NS get configmap | grep velero
# Expected:
# velero-11.1.1-config-defaults   1   30m
# (version number may differ in your environment)
```

**6.2 — Edit the ConfigMap to enable node-agent**

```bash
kubectl -n $VELERO_NS edit configmap velero-<version>-config-defaults
# This opens your default terminal editor (vi or nano)
# Expected after save: configmap/velero-11.1.1-config-defaults edited
```

In the `values.yaml:` block, add `deployNodeAgent: true` after `upgradeCRDs: false`:

```yaml
# Inside the data → values.yaml block — add exactly this line:
upgradeCRDs: false
deployNodeAgent: true
```

> **Important**: the correct key is `deployNodeAgent` (camelCase, one word). Using `nodeAgent.enabled` does nothing in this chart version — it succeeds silently without creating the DaemonSet.

**6.3 — Force Flux to reconcile immediately**

Without this, Flux may wait up to 15 minutes before picking up the change. This forces it now.

```bash
kubectl -n kommander-flux annotate helmrelease velero \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --overwrite
# Expected: helmrelease.helm.toolkit.fluxcd.io/velero annotated
```

**6.4 — Verify node-agent DaemonSet is running**

```bash
kubectl -n $VELERO_NS get daemonset node-agent
# Expected:
# NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
# node-agent   3         3         3       3            3           2m
# (DESIRED should equal the number of nodes in your cluster; all columns should match)
```

```bash
kubectl -n $VELERO_NS get pods -l role=node-agent
# Expected: one pod per node, all Running
# NAME               READY   STATUS    RESTARTS   AGE
# node-agent-abc12   1/1     Running   0          2m
# node-agent-def34   1/1     Running   0          2m
# node-agent-ghi56   1/1     Running   0          2m
```

Repeat Phase 6 on Cluster B.

---

## Phase 7 — Verify both clusters see the same bucket

**What this phase does**: Before triggering any backup, we confirm Velero on both clusters can connect and authenticate to the Objects bucket. If the BSL is not `Available`, the backup will fail immediately.

```bash
kubectl -n $VELERO_NS get backupstoragelocation
# Expected:
# NAME      PHASE       LAST VALIDATED   AGE   DEFAULT
# default   Available   10s              30m   true
```

Run on Cluster B as well. Both must show `Available`.

**If a BSL shows `Unavailable`:**

```bash
# Step 1: Read the specific error from Velero logs
kubectl -n $VELERO_NS logs deployment/velero | grep -i "error\|unavailable\|invalid\|denied" | tail -20
# Common errors and what they mean:
# "InvalidAccessKeyId"     → wrong access key   → redo Phase 4
# "SignatureDoesNotMatch"  → wrong secret key   → redo Phase 4
# "NoSuchBucket"           → bucket name typo   → re-check Phase 5 patch (bucket field)
# "connection refused"     → wrong IP or port   → re-check s3Url in Phase 5
# "tls: certificate"       → TLS error          → verify insecureSkipTLSVerify: "true" is set in BSL
```

```bash
# Step 2: Confirm what values are actually in the BSL
kubectl -n $VELERO_NS get backupstoragelocation default -o yaml | grep -A 15 "spec:"
# Expected: s3Url, bucket, and insecureSkipTLSVerify match what you set in Phase 5
```

```bash
# Step 3: Test network connectivity to the Objects endpoint from inside the cluster
kubectl -n $VELERO_NS run conn-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -sk -o /dev/null -w "%{http_code}" https://<objects-store-ip>:8085
# Expected: 403 or 400
# This means the TCP connection works — the server rejected an unauthenticated request, which is correct
# If you get "000" or "Could not resolve host" → Objects endpoint is unreachable from this cluster's network
```

```bash
# Step 4: Confirm the credential secret has the correct keys
kubectl -n $VELERO_NS get secret dkp-velero -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d
# Expected: your access key from Phase 1
```

---

## Phase 8 — Deploy a test application and run the backup on Cluster A

**What this phase does**: Before taking a backup, we need something to back up. We deploy a simple nginx web application to a dedicated test namespace, then run a Velero backup that captures the entire namespace and uploads it to the Objects bucket.

**8.1 — Deploy the test application**

```bash
kubectl create namespace velero-test
# Expected: namespace/velero-test created
```

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-nginx
  namespace: velero-test
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:stable
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: test-nginx
  namespace: velero-test
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
EOF
# Expected:
# deployment.apps/test-nginx created
# service/test-nginx created
```

```bash
kubectl -n velero-test get pods
# Expected: both pods Running before proceeding
# NAME                          READY   STATUS    RESTARTS   AGE
# test-nginx-6d4cf56db6-abc1   1/1     Running   0          30s
# test-nginx-6d4cf56db6-abc2   1/1     Running   0          30s
```

**8.2 — Run the backup**

```bash
kubectl apply -f velero/cluster-a/backup.yaml
# Expected: backup.velero.io/poc-backup-01 created
```

```bash
kubectl -n $VELERO_NS get backup poc-backup-01 -w
# Expected (updates live — Ctrl+C once Completed appears):
# NAME            STATUS       ERRORS   WARNINGS   CREATED   EXPIRES   STORAGE LOCATION
# poc-backup-01   InProgress   0        0          ...
# poc-backup-01   Completed    0        0          ...
# Takes ~1–2 minutes for stateless workloads; longer if PVC data is large
```

**8.3 — Verify PVC data was captured** *(skip if stateless)*

```bash
kubectl -n $VELERO_NS get podvolumebackup
# Expected: one entry per PVC, all STATUS = Completed
# NAME                              STATUS      STARTED   COMPLETED
# poc-backup-01-xxxxx-volume-0      Completed   ...       ...
```

---

## Phase 9 — Run the restore on Cluster B

**What this phase does**: Since both clusters point to the same Objects bucket, Cluster B automatically discovers all backups that Cluster A created. We apply a restore manifest that tells Velero to recreate the entire namespace — pods, services, and (if stateful) volume data — on Cluster B.

```bash
# Confirm Cluster B can see the backup
kubectl --context=<cluster-b-context> -n $VELERO_NS get backup poc-backup-01
# Expected: same entry as on Cluster A, STATUS = Completed
# If it does not appear yet, wait 30 seconds — Velero syncs from the bucket on a schedule
```

```bash
kubectl --context=<cluster-b-context> apply -f velero/cluster-b/restore.yaml
# Expected: restore.velero.io/poc-restore-01 created
```

```bash
kubectl --context=<cluster-b-context> -n $VELERO_NS get restore poc-restore-01 -w
# Expected (Ctrl+C once Completed):
# NAME             STATUS      ERRORS   WARNINGS
# poc-restore-01   InProgress  0        0
# poc-restore-01   Completed   0        0
```

---

## Phase 10 — Verify restored data on Cluster B

**What this phase does**: Confirm the application and its data landed correctly on Cluster B.

```bash
kubectl --context=<cluster-b-context> -n velero-test get pods
# Expected: same pods as Cluster A, all Running
# NAME                          READY   STATUS    RESTARTS   AGE
# test-nginx-6d4cf56db6-abc1   1/1     Running   0          1m
# test-nginx-6d4cf56db6-abc2   1/1     Running   0          1m
```

```bash
kubectl --context=<cluster-b-context> -n velero-test get svc
# Expected:
# NAME         TYPE        CLUSTER-IP    PORT(S)   AGE
# test-nginx   ClusterIP   10.x.x.x      80/TCP    1m
```

**Verify PVC data** *(skip if stateless)*

```bash
kubectl --context=<cluster-b-context> -n velero-test get pvc
# Expected: same PVCs as Cluster A, STATUS = Bound

# Exec into your database pod and query for data:
kubectl --context=<cluster-b-context> -n <app-namespace> \
  exec -it <db-pod> -- mysql -u root -p<password> <dbname> \
  -e "SELECT COUNT(*) FROM <your-table>;"
# Expected: same row count as on Cluster A
```

---

## Stateless vs. stateful — what you can skip

| Step | Stateless (no PVCs) | Stateful (database/PVC) |
|------|---------------------|------------------------|
| Phase 6 — Enable node-agent | **Skip entirely** | Required |
| `defaultVolumesToFsBackup: true` in backup.yaml | **Remove this line** | Required |
| `restorePVs: true` in restore.yaml | **Remove this line** | Required |
| Phase 8.3 — Verify PodVolumeBackup | **Skip** | Required |
| Phase 10 — PVC and DB verification | **Skip** | Required |

---

## NKP-specific gotchas

| Gotcha | Wrong | Correct |
|--------|-------|---------|
| node-agent Helm key | `nodeAgent.enabled: true` | `deployNodeAgent: true` |
| Flux controller namespace | `flux-system` | `kommander-flux` |
| Credential override via BSL | `spec.credential` overrides env vars | It does not — update credentials at the secret level |
| Cross-cluster backup/restore | Two separate buckets | One shared bucket, same credentials on both clusters |
| Production credential management | Patch `dkp-velero` directly | Use `AppDeployment` + `configOverrides` + user-managed secret |
