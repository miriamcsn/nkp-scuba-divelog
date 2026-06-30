# NKP Install Runbook — Two-Cluster NDK Setup

**Goal:** 1 NKP management cluster (env A) + 2 workload clusters (`nkp-wlc-a` in env A, `nkp-wlc-b` in env B).  
**NKP version:** v2.17.1 | **Method:** NKP Bundle (air-gapped) | **Hypervisor:** AHV

Fill in all `<placeholders>` from [lab-inventory.md](lab-inventory.md) before running.

---

## Table of contents

1. [Prerequisites](#prerequisites)
2. [Phase 1 — Prepare bastion](#phase-1)
3. [Phase 2 — Bootstrap cluster](#phase-2)
4. [Phase 3 — Management cluster (env A)](#phase-3)
5. [Phase 4 — Deploy Kommander](#phase-4)
6. [Phase 5 — Workload cluster A (env A)](#phase-5)
7. [Phase 6 — Workload cluster B (env B)](#phase-6)
8. [Phase 7 — Verify](#phase-7)

---

## <a name="prerequisites"></a>Prerequisites

- [ ] Bastion reachable from both Prism Centrals
- [ ] NKP bundle downloaded and transferred to bastion at `~/nkp-bundle/`
- [ ] Node OS image uploaded to **both** Prism Centrals (same image name)
- [ ] IP ranges reserved in both envs (VIPs for control plane + MetalLB)
- [ ] Local image registry running in each env (or one shared registry reachable cross-env)
- [ ] `nkp` CLI v2.17.1 installed on bastion

```bash
# Verify nkp CLI
nkp version
```

---

## <a name="phase-1"></a>Phase 1 — Prepare bastion

### 1.1 Extract and push bundle to registry

```bash
cd ~/nkp-bundle

# Extract the bundle
tar xzf nkp-v2.17.1-bundle.tar.gz

# Push images to the registry for env A
nkp push bundle \
  --bundle ./nkp-v2.17.1.tar.gz \
  --to-registry <registry-a-url>

# If env B has its own registry:
nkp push bundle \
  --bundle ./nkp-v2.17.1.tar.gz \
  --to-registry <registry-b-url>
```

> **Note:** if both envs share one registry, push once and point both clusters at it.

### 1.2 Upload node OS image to both Prism Centrals

The image must be present in **each** Prism Central before creating clusters.

```bash
# Upload via nkp (repeat for PC-B)
nkp create image nutanix \
  --endpoint https://<pc-a-ip>:9440 \
  --username <pc-username> \
  --password <pc-password>
```

Or upload manually via Prism Central UI → Images.

---

## <a name="phase-2"></a>Phase 2 — Bootstrap cluster

The bootstrap cluster is a local `kind` cluster used to provision the management cluster.

```bash
nkp create bootstrap \
  --registry-mirror-url <registry-a-url> \
  --registry-mirror-cacert <path-to-registry-ca.crt>
```

Verify:

```bash
kubectl get nodes          # should show bootstrap-control-plane node
kubectl cluster-info
```

---

## <a name="phase-3"></a>Phase 3 — Management cluster (env A)

### 3.1 Create management cluster

```bash
nkp create cluster nutanix \
  --cluster-name nkp-mgmt \
  --control-plane-endpoint-ip <mgmt-vip-a> \
  --control-plane-prism-element-cluster <pe-cluster-a> \
  --control-plane-subnets <subnet-a> \
  --control-plane-vm-image <node-image-a> \
  --control-plane-replicas 3 \
  --worker-prism-element-cluster <pe-cluster-a> \
  --worker-subnets <subnet-a> \
  --worker-vm-image <node-image-a> \
  --worker-replicas 4 \
  --csi-storage-container default \
  --endpoint https://<pc-a-ip>:9440 \
  --nutanix-username <pc-username> \
  --nutanix-password <pc-password> \
  --registry-mirror-url <registry-a-url> \
  --registry-mirror-cacert <path-to-registry-ca.crt> \
  --self-managed
```

`--self-managed` moves Cluster API components into the cluster itself (no separate bootstrap dependency after this).

### 3.2 Monitor provisioning

```bash
nkp describe cluster nkp-mgmt
# Wait until all machines are Running (~10–15 min)
```

### 3.3 Get kubeconfig

```bash
nkp get kubeconfig --cluster-name nkp-mgmt > ~/.kube/nkp-mgmt.kubeconfig
export KUBECONFIG=~/.kube/nkp-mgmt.kubeconfig
kubectl get nodes
```

---

## <a name="phase-4"></a>Phase 4 — Deploy Kommander

```bash
nkp install kommander \
  --installer-config kommander-installer.yaml \
  --kubeconfig ~/.kube/nkp-mgmt.kubeconfig
```

> If air-gapped, use the Kommander bundle:
> ```bash
> nkp install kommander \
>   --installer-config kommander-installer.yaml \
>   --kommander-applications-repository <path-to-kommander-bundle> \
>   --kubeconfig ~/.kube/nkp-mgmt.kubeconfig
> ```

Wait for all pods:

```bash
kubectl -n kommander get pods --watch
```

Get Kommander URL and credentials:

```bash
nkp open dashboard --kubeconfig ~/.kube/nkp-mgmt.kubeconfig
```

---

## <a name="phase-5"></a>Phase 5 — Workload cluster A (env A)

```bash
nkp create cluster nutanix \
  --cluster-name nkp-wlc-a \
  --control-plane-endpoint-ip <wlc-a-vip> \
  --control-plane-prism-element-cluster <pe-cluster-a> \
  --control-plane-subnets <subnet-a> \
  --control-plane-vm-image <node-image-a> \
  --control-plane-replicas 3 \
  --worker-prism-element-cluster <pe-cluster-a> \
  --worker-subnets <subnet-a> \
  --worker-vm-image <node-image-a> \
  --worker-replicas 4 \
  --csi-storage-container default \
  --endpoint https://<pc-a-ip>:9440 \
  --nutanix-username <pc-username> \
  --nutanix-password <pc-password> \
  --registry-mirror-url <registry-a-url> \
  --registry-mirror-cacert <path-to-registry-ca.crt> \
  --kubeconfig ~/.kube/nkp-mgmt.kubeconfig
```

Get kubeconfig:

```bash
nkp get kubeconfig --cluster-name nkp-wlc-a \
  --kubeconfig ~/.kube/nkp-mgmt.kubeconfig \
  > ~/.kube/nkp-wlc-a.kubeconfig

kubectl --kubeconfig ~/.kube/nkp-wlc-a.kubeconfig get nodes
```

---

## <a name="phase-6"></a>Phase 6 — Workload cluster B (env B)

Same command as Phase 5 but targeting **Prism Central B** and the env B registry.

```bash
nkp create cluster nutanix \
  --cluster-name nkp-wlc-b \
  --control-plane-endpoint-ip <wlc-b-vip> \
  --control-plane-prism-element-cluster <pe-cluster-b> \
  --control-plane-subnets <subnet-b> \
  --control-plane-vm-image <node-image-b> \
  --control-plane-replicas 3 \
  --worker-prism-element-cluster <pe-cluster-b> \
  --worker-subnets <subnet-b> \
  --worker-vm-image <node-image-b> \
  --worker-replicas 4 \
  --csi-storage-container default \
  --endpoint https://<pc-b-ip>:9440 \
  --nutanix-username <pc-username> \
  --nutanix-password <pc-password> \
  --registry-mirror-url <registry-b-url> \
  --registry-mirror-cacert <path-to-registry-b-ca.crt> \
  --kubeconfig ~/.kube/nkp-mgmt.kubeconfig
```

Get kubeconfig:

```bash
nkp get kubeconfig --cluster-name nkp-wlc-b \
  --kubeconfig ~/.kube/nkp-mgmt.kubeconfig \
  > ~/.kube/nkp-wlc-b.kubeconfig

kubectl --kubeconfig ~/.kube/nkp-wlc-b.kubeconfig get nodes
```

---

## <a name="phase-7"></a>Phase 7 — Verify

```bash
# Both workload clusters visible in management
kubectl --kubeconfig ~/.kube/nkp-mgmt.kubeconfig get clusters -A

# All nodes Ready in each cluster
kubectl --kubeconfig ~/.kube/nkp-wlc-a.kubeconfig get nodes
kubectl --kubeconfig ~/.kube/nkp-wlc-b.kubeconfig get nodes

# CSI running in both
kubectl --kubeconfig ~/.kube/nkp-wlc-a.kubeconfig get pods -n ntnx-system
kubectl --kubeconfig ~/.kube/nkp-wlc-b.kubeconfig get pods -n ntnx-system

# StorageClass available
kubectl --kubeconfig ~/.kube/nkp-wlc-a.kubeconfig get sc
kubectl --kubeconfig ~/.kube/nkp-wlc-b.kubeconfig get sc
```

All green? You're ready to install NDK on both workload clusters — see next runbook.

---

## Gotchas

| Issue | Fix |
|-------|-----|
| `nkp create bootstrap` fails — Docker/podman not running | `podman machine start` (or `docker start`) |
| Image not found on PC | Upload node OS image manually via PC UI → Images |
| Control plane VIP unreachable | Confirm IP is in the reserved range and not used by any VM |
| Registry pull errors | Check CA cert path and that the registry is reachable from every cluster node |
| `--self-managed` flag | Only for management cluster — omit for workload clusters |
| wlc-b nodes can't reach registry-a | Either use per-env registries, or ensure cross-env network routing |
