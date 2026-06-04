# NDK Sealed Secrets Runbook

> **Placeholders** — replace these with your actual values before running any command:
> - `<cluster-a>` / `<cluster-b>` — your NKP cluster names
> - `<app-namespace>` — namespace where the app runs (same on both clusters)
> - `<backup-namespace>` — namespace where NDK snapshot replicas land
> - `<your-app-domain>` — the DNS name fronted by HAProxy
> - `<haproxy-vm-ip>` — IP of the HAProxy VM

---

## Namespaces

| Cluster | App runs here | NDK snapshots land here |
|---------|--------------|------------------------|
| A (`<cluster-a>`) | `<app-namespace>` | `<backup-namespace>` |
| B (`<cluster-b>`) | `<app-namespace>` | `<backup-namespace>` |

## Access
- **URL:** `https://<your-app-domain>`
- DNS points permanently to the HAProxy VM — never changes during failover/failback
- HAProxy health-checks both cluster ingresses and routes automatically to whichever is alive
- ⚠️ If the domain resolves to a private IP, you must be on the same network as the clusters

## HAProxy (load balancer VM)
- **VM:** your bootstrap/bastion host
- **Config:** `/etc/haproxy/haproxy.cfg`
- **Cert:** `/etc/haproxy/certs/scuba.pem`
- **Backends:** cluster A `<cluster-a-ingress-ip>:443` (primary), cluster B `<cluster-b-ingress-ip>:443` (backup)
- **Health check:** `GET /healthz` with `Host: <your-app-domain>` — automatic failover when nginx is gone

### Starting HAProxy after the VM reboots or the service goes down
```bash
# SSH into the bootstrap VM
ssh <user>@<haproxy-vm-ip>

# Start and verify
sudo systemctl start haproxy
sudo systemctl status haproxy

# Confirm it's listening on 443
sudo ss -tlnp | grep haproxy

# If config is broken, validate before starting
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

> HAProxy is enabled at boot (`systemctl enable` was run at install time) so a clean reboot should bring it back automatically. Use the commands above only if it fails to start.

---

## NDK Objects

| Object | What it does |
|--------|-------------|
| `Application` | Declares what to protect — discovers pods, PVCs, etc. by label selector (`app.kubernetes.io/instance: scuba`) |
| `ReplicationTarget` | Destination address — points to the remote cluster and namespace where snapshots are sent |
| `JobScheduler` | Timer only — fires every 60 minutes; doesn't know what to do, just triggers |
| `ProtectionPlan` | The backup rules — wires together the where (`ReplicationTarget`) + the when (`JobScheduler`) + retention (keep last 3 snapshots) |
| `AppProtectionPlan` | Top-level glue — connects the `Application` to one or more `ProtectionPlan`s; this is what kicks everything off |
| `ReferenceGrant` | Cross-namespace permission slip — lets `<app-namespace>` reach into `<backup-namespace>` to restore snapshots |

---

## Initial Setup (one-time)

### 1. Create namespaces on both clusters
```bash
# Cluster A
export KUBECONFIG=~/.kube/<cluster-a>-kubeconfig.conf
kubectl create namespace <app-namespace>
kubectl create namespace <backup-namespace>

# Cluster B
export KUBECONFIG=~/.kube/<cluster-b>-kubeconfig.conf
kubectl create namespace <app-namespace>
kubectl create namespace <backup-namespace>
```

### 2. Install Sealed Secrets controller on BOTH clusters
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

# Cluster A
export KUBECONFIG=~/.kube/<cluster-a>-kubeconfig.conf
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace <app-namespace> --version 2.17.2

# Cluster B
export KUBECONFIG=~/.kube/<cluster-b>-kubeconfig.conf
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace <app-namespace> --version 2.17.2
```

### 3. Apply sealed secrets (Cloudflare token + app secrets)
```bash
# Cluster A
export KUBECONFIG=~/.kube/<cluster-a>-kubeconfig.conf
kubectl apply -f ndk-sealed/sealed-cloudflare-token.yaml
kubectl apply -f sealed-secrets/sealed-mysql-secret.yaml
kubectl apply -f sealed-secrets/sealed-app-db-secret.yaml

# Cluster B
export KUBECONFIG=~/.kube/<cluster-b>-kubeconfig.conf
kubectl apply -f ndk-sealed/sealed-cloudflare-token.yaml
kubectl apply -f sealed-secrets/sealed-mysql-secret.yaml
kubectl apply -f sealed-secrets/sealed-app-db-secret.yaml
```

### 4. DNS (one-time)
`<your-app-domain>` A record points to the HAProxy VM. No ExternalDNS needed — HAProxy handles failover automatically via health checks.

### 5. Apply NDK manifests
```bash
# Cluster A — source
export KUBECONFIG=~/.kube/<cluster-a>-kubeconfig.conf
kubectl apply -f ndk-sealed/source-ndk.yaml
kubectl apply -f ndk-sealed/refgrant.yaml   # ⚠️ required on BOTH clusters

# Cluster B — target
export KUBECONFIG=~/.kube/<cluster-b>-kubeconfig.conf
kubectl apply -f ndk-sealed/target-ndk.yaml
kubectl apply -f ndk-sealed/refgrant.yaml   # ⚠️ required on BOTH clusters
```

> **⚠️ Lesson learned:** `refgrant.yaml` must be applied on **both** clusters.
> Without it on cluster A, failback will fail with "Unauthorised to access the ApplicationSnapshot".

### 6. Deploy the app and seed data
```bash
export KUBECONFIG=~/.kube/<cluster-a>-kubeconfig.conf
helm install scuba deploy/charts/scuba-divelog --namespace <app-namespace>
./scripts/seed-scuba-v3.sh
```

---

## Failover (A → B)

> Wait for at least 1 snapshot to replicate before proceeding.
> Check: `kubectl get applicationsnapshotreplications -n <app-namespace>`

```bash
# 1. Clean up cluster A — uninstall Helm release and delete PVC
export KUBECONFIG=~/.kube/<cluster-a>-kubeconfig.conf
helm uninstall scuba -n <app-namespace> 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n <app-namespace> 2>/dev/null || true

# 2. Clean up cluster B — remove any leftover app resources from previous failover
#    ✅ sealed-secrets controller must stay running — do NOT delete it
export KUBECONFIG=~/.kube/<cluster-b>-kubeconfig.conf
helm uninstall scuba -n <app-namespace> 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n <app-namespace> 2>/dev/null || true

# 3. Get the latest snapshot name on cluster B
kubectl get applicationsnapshots -n <backup-namespace>

# 4. Apply the restore (replace <SNAPSHOT-NAME> with the latest READY-TO-USE one)
kubectl delete applicationsnapshotrestore restore-failover -n <app-namespace> 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshotRestore
metadata:
  name: restore-failover
  namespace: <app-namespace>
spec:
  applicationSnapshotName: <SNAPSHOT-NAME>
  applicationSnapshotNamespace: <backup-namespace>
EOF

# 5. Watch restore progress
kubectl get applicationsnapshotrestore restore-failover -n <app-namespace> -w

# 6. Force Helm to take ownership of restored resources
helm upgrade --install scuba deploy/charts/scuba-divelog \
  --namespace <app-namespace> \
  --force-conflicts

# 7. Verify app is accessible at https://<your-app-domain>
# HAProxy detects cluster B is healthy via /healthz and routes automatically
```

---

## Failback (B → A)

```bash
# 1. Clean up cluster A — uninstall Helm release and delete PVC
export KUBECONFIG=~/.kube/<cluster-a>-kubeconfig.conf
helm uninstall scuba -n <app-namespace> 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n <app-namespace> 2>/dev/null || true

# 2. Get the latest snapshot name on cluster A
kubectl get applicationsnapshots -n <backup-namespace>

# 3. Apply the restore (replace <SNAPSHOT-NAME> with the latest READY-TO-USE one)
kubectl delete applicationsnapshotrestore restore-failback -n <app-namespace> 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: dataservices.nutanix.com/v1alpha1
kind: ApplicationSnapshotRestore
metadata:
  name: restore-failback
  namespace: <app-namespace>
spec:
  applicationSnapshotName: <SNAPSHOT-NAME>
  applicationSnapshotNamespace: <backup-namespace>
EOF

# 4. Watch restore progress
kubectl get applicationsnapshotrestore restore-failback -n <app-namespace> -w

# 5. Force Helm to take ownership of restored resources
helm upgrade --install scuba deploy/charts/scuba-divelog \
  --namespace <app-namespace> \
  --force-conflicts

# 6. Clean up cluster B — remove app resources now that app is back on A
#    ✅ sealed-secrets controller must stay running — do NOT delete it
export KUBECONFIG=~/.kube/<cluster-b>-kubeconfig.conf
helm uninstall scuba -n <app-namespace> 2>/dev/null || true
kubectl delete pvc data-scuba-mysql-0 -n <app-namespace> 2>/dev/null || true

# 7. Verify app is accessible at https://<your-app-domain>
# HAProxy detects cluster A is healthy via /healthz and routes automatically
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Restore fails: "Unauthorised to access ApplicationSnapshot" | ReferenceGrant missing | `kubectl apply -f ndk-sealed/refgrant.yaml` on the target cluster |
| Restore fails: "Resources already exist" | Helm release still installed | `helm uninstall scuba -n <app-namespace>` before restoring |
| MySQL pod: "secret not found" | SealedSecrets not labelled | Ensure `app.kubernetes.io/instance: scuba` label is on SealedSecret templates |
| DNS resolves to Cloudflare IPs | Proxying enabled | Set DNS-only (grey cloud) on the A record in Cloudflare |
| 503 on `https://<your-app-domain>` | HAProxy health check failing — nginx not yet ready | Wait for `kubectl rollout status deployment/scuba-frontend -n <app-namespace>` to complete |
| HAProxy down | Service stopped | SSH into the HAProxy VM and run `sudo systemctl restart haproxy` |
| "No available server" | Two wildcard ingresses conflicting | Annotate the conflicting ingress: `kubectl annotate ingress scuba -n <app-namespace> traefik.ingress.kubernetes.io/router.entrypoints=none` |
