# Velero, from Zero — A Practical Walkthrough for POC Architects

This is a **self-contained, shareable-with-the-customer** guide: every command
you need to reproduce this Velero POC yourself is inline below, in order, next to
an explanation of *why* that step exists and what Velero concept it's teaching.
It's meant to be handed to a customer's team so they can run it themselves and
actually understand what happened, not just paste commands blindly.

(A terser, no-narration version of the same commands — for when you already know
this material and just need the copy-paste — lives in
[`runbook-velero.md`](./runbook-velero.md).)

Written for: an architect who knows Kubernetes but hasn't necessarily run Velero
before, and needs to both set it up *and* explain it to a customer during a POC.
Every worked example below is real — it's what we actually hit setting up Velero
against Nutanix Objects on a live NKP cluster, not a hypothetical.

---

## Prerequisites checklist

Gather all of this before running anything below — it's what turns this from a
multi-hour trial-and-error session into a straight run-through. Every check is:
run the command, compare to the expected output, and if it doesn't match, do
the fix — don't just eyeball the checkbox.

### Local tools

**`kubectl`**

```bash
kubectl version --client
```

Expected: a version block with no errors, e.g. `Client Version: v1.29.x`.
If missing: install it (`brew install kubectl` on macOS, or your platform's
package manager / the Kubernetes docs).

**`helm`** (installs Sealed Secrets and the demo app's chart)

```bash
helm version
```

Expected: `version.BuildInfo{Version:"v3.x.x", ...}` (or `v4.x.x` — Helm 4
changes some upgrade internals, see the `--force-conflicts` explanation in
Part 6).
If missing: `brew install helm`.

**`velero` CLI**

```bash
velero version --client-only
```

Expected:

```text
Client:
    Version: v1.18.1
    Git commit: -
```

(`--client-only` avoids an error here since the server isn't installed yet.)
If missing: `brew install velero`, or download from
`github.com/vmware-tanzu/velero/releases`.

**`kubeseal` CLI** (only if your app uses Sealed Secrets, like our demo app does)

```bash
kubeseal --version
```

Expected: `kubeseal version: v0.2x.x`.
If missing: `brew install kubeseal`.

### Cluster access

**Correct context selected** — critical if contexts are named ambiguously
(ours were IP-only, `wonderful_fermi-<ip>`, for both the management cluster
and every workload cluster it manages):

```bash
kubectl config get-contexts
kubectl config use-context <your-workload-cluster-context>
kubectl get nodes
```

Expected: a list of `Ready` nodes whose **names** identify the cluster you
meant to target, not the management cluster.
If wrong cluster: `kubectl config use-context <correct-context>` and
re-check — don't proceed until the node names confirm you're in the right
place.

**CSI driver + `VolumeSnapshotClass` already exist** (Velero doesn't install
these — they're a separate prerequisite it depends on):

```bash
kubectl get storageclass
```

Expected: at least one storage class with a real CSI `PROVISIONER`, e.g.:

```text
NAME                       PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
nutanix-volume (default)   csi.nutanix.com   Delete          WaitForFirstConsumer   true                   35h
```

```bash
kubectl get volumesnapshotclass
```

Expected: at least one entry, e.g.:

```text
NAME                     DRIVER            DELETIONPOLICY   AGE
nutanix-snapshot-class   csi.nutanix.com   Retain           34h
```

If either returns nothing: CSI snapshotting isn't configured on this
cluster — that's infrastructure the customer's storage admin needs to set up
first, not something fixable from the Velero side. (Fallback: File System
Backup mode works without CSI snapshot support, at the cost of slower
backups/restores — see Part 2.)

**Outbound internet egress to Docker Hub** (`velero install` pulls
`docker.io/velero/velero` and the AWS plugin image):

```bash
kubectl run egress-test --image=docker.io/velero/velero:v1.18.1 --restart=Never -- true
sleep 5
kubectl describe pod egress-test | tail -10
kubectl delete pod egress-test
```

Expected: an Event line reading `Successfully pulled image
"docker.io/velero/velero:v1.18.1"` (the pod itself may then error out or
complete oddly since `velero`'s image isn't meant to run standalone with
`true` as an override — that part doesn't matter, only the pull event does).
If it hangs in `ImagePullBackOff` with no successful pull event: no egress —
you'll need an internal registry mirror and must reference the mirrored image
paths in `--plugins` at install time (Part 4).

### From the customer's Nutanix Objects admin — don't guess any of these

- [ ] A bucket already provisioned, dedicated to Velero
- [ ] An access key + secret key pair
- [ ] Confirmation that key has been **explicitly granted access to that bucket**
  (a valid key alone is not enough — see Gotcha #1 in Part 3)
- [ ] The Object Store's base endpoint/FQDN (not a bucket-prefixed hostname)
- [ ] The region string configured for that store (commonly `us-east-1` — see
  Gotcha #3 in Part 3)
- [ ] Whether the endpoint uses a self-signed/internal CA cert

Once you have all four, verify the endpoint itself **before** running `velero
install` — catches DNS/addressing-style/TLS problems early instead of buried
in a server log. If the hostname is internal-only (ours was), run this from a
throwaway pod, not your laptop:

```bash
kubectl run objects-check --image=curlimages/curl:8.10.1 --restart=Never --rm -it -- \
  curl -sk -o /dev/null -w "HTTP %{http_code}\n" https://<endpoint>/<bucket>/
```

Expected: `HTTP 403` — a **good** sign here, it means the server answered
with a real S3 `AccessDenied` response, confirming the endpoint, hostname,
and path-style addressing all work; you just haven't authenticated yet, which
is expected for this quick check.
If it hangs/times out/`curl: (6) Could not resolve host`: wrong endpoint, or
you need to run this from inside the cluster instead of your laptop (internal
DNS names often don't resolve externally).
If it errors on the TLS handshake (`curl: (60)`): self-signed/internal CA
cert — you'll need `insecureSkipTLSVerify: "true"` in Part 4.

**Decided ahead of time:**

- [ ] The namespace your app will run in, and (if demoing migration on one
  cluster) the namespace you'll restore into

---

## Part 1 — What Velero actually is, before you touch a command

Skip this part and you'll still be able to copy commands from the runbook. But
you won't be able to answer the customer's first question, which is always some
version of: **"how is this different from what our storage already does?"**

### The problem Velero solves

A Kubernetes application isn't just data on a disk. It's a *shape* — Deployments,
Services, ConfigMaps, Secrets, an Ingress, the PVCs, and the actual bytes sitting
on the volumes those PVCs point to. If you only snapshot the storage (say, a
Nutanix volume group snapshot), you get the bytes back, but not the shape: you'd
still have to hand-reconstruct every Kubernetes object around it before that data
means anything again. If you only run `kubectl get -o yaml` on everything, you get
the shape, but not the bytes inside the volumes.

Velero backs up **both**, together, as one coherent unit, and stores the result
somewhere that survives even if the entire cluster is destroyed. That combination
— shape + data + off-cluster durability — is what makes it useful for three
distinct use cases that all end up looking similar operationally:

- **Disaster recovery**: cluster dies, you rebuild a new one and restore into it.
- **Migration**: moving an app from cluster A to cluster B on purpose (what our
  POC demonstrates — we did it same-cluster into a different namespace as a
  stand-in, since the mechanism is identical for cross-cluster).
- **Point-in-time restore**: someone deleted a namespace by accident, or a bad
  deploy corrupted data — roll back to yesterday's backup.

### The three things a Backup actually contains

1. **Kubernetes object manifests** — every resource in the included namespace(s):
   Deployments, Services, ConfigMaps, Secrets, PVCs, the works. This is captured
   by talking to the Kubernetes API server directly, the same way `kubectl get`
   does. Cheap, fast, and this part alone is often 90% of what people actually
   need restored.
2. **Persistent volume data** — the actual bytes on each PVC. Velero has two
   fundamentally different ways to capture this (covered in Part 2) — which one
   you use depends on what your storage/CSI driver supports.
3. **A pointer to where all of the above lives** — Velero doesn't store any of
   this inside the Kubernetes cluster itself (that would defeat the entire point:
   if the cluster dies, an in-cluster backup dies with it). It uploads everything
   to an S3-compatible object store *outside* the cluster. That's the "Objects
   part" of this guide's title, and it's Part 3 below.

### Velero's plugin architecture

Velero's core doesn't know anything about AWS, Azure, GCP, or Nutanix. It talks to
external systems entirely through plugins:

- **Object store plugins** — how Velero talks to S3, GCS, Azure Blob, or (our
  case) any S3-*compatible* store. We use `velero-plugin-for-aws`, not because
  we're on AWS, but because Nutanix Objects speaks the S3 API, and that plugin is
  really "the S3-protocol plugin" wearing an AWS-branded name.
- **Volume snapshotter plugins / CSI support** — how Velero triggers a snapshot of
  a PV. Modern Velero (v1.14+) has CSI snapshot support built into the core
  server — no separate plugin binary needed, just a feature flag at install time.

This plugin model is *why* Velero works identically on AWS, on-prem VMware, or
(our case) Nutanix: swap the object store plugin and the snapshot mechanism, the
rest of the workflow — Backup, Restore, Schedule — never changes.

---

## Part 2 — Two ways to capture volume data (and why we picked one)

This is the single most important architectural decision you'll make in a Velero
POC, and it's worth explaining to the customer explicitly, because it changes what
"restore" actually looks like.

**Option A — CSI snapshots.** Velero asks your storage's CSI driver to take a
native, storage-level snapshot of the volume (same mechanism `kubectl` would use
if you created a `VolumeSnapshot` object by hand). Fast, efficient, and the
snapshot lives in your storage backend, not inside the backup tarball. Requires:
your CSI driver to support the Kubernetes `VolumeSnapshot` API, and a
`VolumeSnapshotClass` for it. **This is what we used** — Nutanix's CSI driver
(`csi.nutanix.com`) supports it, and there was already a `VolumeSnapshotClass`
(`nutanix-snapshot-class`) sitting on the cluster.

**Option B — File System Backup (Kopia)**, formerly called Restic integration.
Velero runs a file-level backup agent (`node-agent` DaemonSet) that reads the
volume's files directly and uploads them as part of the backup, byte by byte.
Works with *any* storage, even ones with no CSI snapshot support, but slower and
more resource-intensive since it's a real file copy, not a storage-level pointer.

We used **CSI snapshots** (`snapshotVolumes: true`, `defaultVolumesToFsBackup:
false` in the `Backup` spec). The practical difference the customer will notice:
CSI-snapshot restores are fast because the storage backend just clones the
snapshot into a new volume; FSB restores are slower because every file gets
copied back over the wire.

> **Worked example:** confirm your CSI driver supports this before promising it
> to a customer:
>
> ```bash
> kubectl get storageclass          # note the provisioner, e.g. csi.nutanix.com
> kubectl get volumesnapshotclass   # if this returns nothing, CSI snapshotting
>                                    # isn't configured yet — that's a blocker,
>                                    # not a Velero problem
> ```

---

## Part 3 — The "Objects" part: setting up the S3-compatible backend

This is the part of a Velero POC that has nothing to do with Velero and
everything to do with the customer's object storage — and it's usually where the
most time gets lost, because the failure modes (wrong region, wrong permissions,
wrong addressing style) all look like generic "connection failed" errors if you
don't know what you're looking at. We're going to walk through *why* each of
these settings exists, not just what value to type in.

### Why an external object store at all?

Repeat the DR logic from Part 1: if backups lived inside the cluster they're
protecting, a cluster-destroying event destroys the backups too. Velero needs
storage that exists independently of the cluster — this is non-negotiable for any
real DR story, and it's why "just back up to a PVC" isn't a real option.

### What Nutanix Objects is, in one sentence

It's Nutanix's S3-API-compatible object storage service (runs as its own
service/cluster inside Prism Central, sometimes called "Buckets" in the UI) — from
Velero's point of view, it's indistinguishable from talking to real AWS S3, which
is exactly the point: any tool that speaks the S3 protocol works against it
without modification.

### Setting it up (customer/admin side, via Prism Central)

You as the POC architect usually won't provision the Object Store itself — that's
infrastructure the customer's Nutanix admin sets up ahead of time (it's its own
deployment, with its own worker VMs). What *you* need from them, concretely:

1. **A bucket**, dedicated to Velero (don't share it with other workloads —
   makes lifecycle/retention policies and troubleshooting much simpler). Ours was
   named `velero`.
2. **An access key + secret key pair**, created for a specific user in the
   Objects console.
3. **That user explicitly granted permission on that bucket.** This is the
   single biggest gotcha we hit, so it gets its own callout below.
4. **The Object Store's endpoint/FQDN** — e.g. `objects.ntnxlab.local`. Get the
   *base* hostname, not a bucket-specific one (see path-style vs virtual-hosted
   below for why that distinction matters).

### Gotcha #1 — a valid key pair isn't the same as bucket access

In AWS IAM, a lot of accounts are broadly permissive by default and people forget
permissions are even a separate axis from authentication. Nutanix Objects
enforces the distinction more visibly: creating an access key just proves *who
you are*; it grants **zero** bucket permissions by itself. A separate,
bucket-level policy grant is required before that key can read/write a specific
bucket.

The failure mode is deceptive: an unauthorized-but-valid key and a
wrong/malformed key produce the **exact same error** — `403 AccessDenied` — with
no distinction in the response. We proved this the hard way: same error,
authenticated or not, until the bucket-level grant was added in Prism Central,
at which point it worked immediately with no other change.

> **Teaching point for the customer:** when `velero backup-location get` shows
> `Unavailable`, don't assume the key is typo'd — check the bucket's permission
> grants first. It's the more common root cause in our experience.

### Gotcha #2 — path-style vs. virtual-hosted-style addressing

S3 supports two ways to address a bucket in a URL:

- **Virtual-hosted-style**: the bucket name is a DNS subdomain —
  `https://<bucket>.<endpoint>/object-key`. This is AWS's modern default, but it
  requires wildcard DNS and a wildcard (or SAN) TLS cert covering every possible
  bucket subdomain.
- **Path-style**: the bucket name is the first path segment —
  `https://<endpoint>/<bucket>/object-key`. No special DNS or cert setup needed
  beyond the base hostname.

On-prem S3-compatible stores almost never have wildcard DNS configured for
arbitrary bucket subdomains, so **path-style is the safe default** unless you've
specifically confirmed virtual-hosted works. We confirmed this by literally
testing both from inside the cluster:

```bash
# path-style base endpoint — this resolved and answered
curl -sk https://objects.ntnxlab.local/velero/

# virtual-hosted style — this didn't even resolve in DNS
curl -sk https://velero.objects.ntnxlab.local/
```

In Velero's `BackupStorageLocation` config, this is the `s3ForcePathStyle: "true"`
setting — force path-style, don't let the SDK default to virtual-hosted.

### Gotcha #3 — the "region" field is real, even on-prem

This one surprises people the most: **"region" isn't an AWS-only concept you can
ignore because you're not on AWS.** The S3 protocol's request-signing scheme
(SigV4) embeds a region string in every authenticated request, and the object
store validates that the signed region matches the bucket's actual configured
region. Get it wrong, and you get a very specific, very confusing error:

```text
IllegalLocationConstraintException: Attempting to access a bucket from a
different region than where the bucket exists.
```

That's not a typo in your credentials — it's the *region string* that's wrong.
Nutanix Objects (like most S3-compatible implementations) defaults new stores to
the conventional AWS placeholder region `us-east-1`, purely for compatibility with
tools that assume it exists. We found this by testing: `region: default` produced
the `IllegalLocationConstraintException` above; `region: us-east-1` made it go
away entirely (revealing the *actual* remaining problem, which was gotcha #1).

> **Teaching point:** never guess this value freely. If the customer's admin
> doesn't know it offhand, `us-east-1` is the correct first guess for
> Nutanix Objects specifically — but confirm it, don't assume it for every
> S3-compatible product.

### Gotcha #4 — self-signed / internal CA certificates

Nearly every on-prem object store you'll POC against uses a certificate issued by
an internal or self-signed CA, not a public one. Velero's S3 client validates TLS
by default and will refuse to connect otherwise. The fix is
`insecureSkipTLSVerify: "true"` in the `BackupStorageLocation` config — explain to
the customer this is a POC/lab convenience, and that a production rollout should
instead trust the internal CA properly (via `--cacert` / a mounted CA bundle)
rather than disabling verification outright.

### Putting it together: the BackupStorageLocation

Once you have all four pieces (bucket, keys+grant, path-style confirmed, region
confirmed), they combine into one Kubernetes object Velero manages internally —
the `BackupStorageLocation` (BSL). You don't usually author this by hand; `velero
install` generates it from CLI flags (Part 4). But it's worth seeing what it looks
like, because `velero backup-location get` reporting `Available` vs `Unavailable`
is your single fastest health check for the entire object-storage integration:

```yaml
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: velero
spec:
  provider: aws                  # "aws" = the S3-protocol plugin, not literally AWS
  objectStorage:
    bucket: velero
  config:
    region: us-east-1
    s3ForcePathStyle: "true"
    s3Url: https://objects.ntnxlab.local
    insecureSkipTLSVerify: "true"
```

---

## Part 4 — Installing Velero

With Part 3's four values in hand, installation itself is almost anticlimactic —
which is the point. All the hard-won knowledge front-loads into configuration
values; the install command is generic.

### 4.1 — Point kubectl at the right cluster, and get an app running to back up

Velero needs something to actually protect. If contexts are named ambiguously
(ours were IP-only, `wonderful_fermi-<ip>`, for both the management cluster and
the workload cluster), confirm you're on the right one before doing anything
else:

```bash
kubectl config get-contexts
kubectl config use-context <your-workload-cluster-context>

kubectl get nodes   # sanity check: node names should identify the right cluster
```

Create the namespace the app will run in:

```bash
kubectl create namespace miriam-velero
```

> **If your app's Secrets are managed by Sealed Secrets** (as our demo app's
> are), they're encrypted for one specific cluster + namespace and won't decrypt
> anywhere else — including a brand-new namespace on the *same* cluster. Install
> the controller and reseal for this namespace before deploying:
>
> ```bash
> helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
> helm repo update sealed-secrets
> helm install sealed-secrets sealed-secrets/sealed-secrets \
>   --namespace sealed-secrets --create-namespace --wait --timeout 3m
>
> NAMESPACE=miriam-velero MYSQL_DATABASE=divelog MYSQL_ROOT_PASSWORD=rootpw \
>   ./scripts/reseal-secrets.sh
> ```
>
> If your app doesn't use Sealed Secrets, skip straight to the next command.

Deploy the app and put some real data in it — an empty app makes a very
unconvincing demo backup:

```bash
helm install scuba deploy/charts/scuba-divelog --namespace miriam-velero
kubectl -n miriam-velero get pods -w        # wait for everything Running

NAMESPACE=miriam-velero ./scripts/seed-scuba-v3.sh
```

### 4.2 — Install the CLI

The `velero` binary is a client — it talks to the Velero server running in-cluster
via the Kubernetes API, the same way `kubectl` talks to the API server. It's also
what generates the server-side install manifests.

```bash
brew install velero      # or download from github.com/vmware-tanzu/velero/releases
velero version --client-only
```

### 4.3 — Enable CSI snapshotting on your VolumeSnapshotClass

Velero's CSI support (built into the server core since v1.14) only uses
`VolumeSnapshotClass` objects that carry a specific label — this is how Velero
knows *which* snapshot class to use if a cluster has several:

```bash
kubectl label volumesnapshotclass nutanix-snapshot-class \
  velero.io/csi-volumesnapshot-class=true
```

Expected: `volumesnapshotclass.snapshot.storage.k8s.io/nutanix-snapshot-class
labeled`.

This is additive — it doesn't change how anything else that already references
this snapshot class behaves. Safe to run even on a snapshot class other workloads
depend on.

> **Cluster-wide, not per-namespace:** `VolumeSnapshotClass` is a
> cluster-scoped resource, not namespaced — so this only needs to run **once
> per cluster**, not once per app/namespace. If you've already run this once
> on this cluster and are repeating the walkthrough for a new namespace,
> you'll instead see `volumesnapshotclass.snapshot.storage.k8s.io/nutanix-snapshot-class
> not labeled` — that's not an error, it means the label is already there from
> last time (`kubectl label` without `--overwrite` prints "not labeled" when
> the requested label:value already matches, i.e. nothing needed to change).
> Verify with `kubectl get volumesnapshotclass nutanix-snapshot-class
> --show-labels` and move straight on to 4.4.

### 4.4 — Write the credentials file

Velero's AWS-protocol plugin expects credentials in the same flat-file format the
AWS CLI itself uses — an INI-style file with one profile:

```bash
cp velero/credentials-velero.example velero/credentials-velero
```

Then edit `velero/credentials-velero` and fill in the real values:

```ini
[default]
aws_access_key_id=<your access key>
aws_secret_access_key=<your secret key>
```

Treat this like any other credential file: never commit it to git. (In our repo,
`velero/credentials-velero` is gitignored on purpose — the `.gitignore` entry
already covers it — with a `.example` template checked in instead.)

The `cp` step matters more than it looks: it copies the **template** file
(`credentials-velero.example`, tracked in git, placeholder values only) to a
**real** file (`credentials-velero`, gitignored) that you then edit with your
actual key. `velero install` (4.5) reads this file once, to create the
`cloud-credentials` Secret the running Velero server actually authenticates
with.

> **Cluster-wide, not per-namespace** (same idea as 4.3): Velero is installed
> once per cluster, so this file only needs to be created/filled in once per
> cluster too. If you're repeating this walkthrough for a new namespace on a
> cluster where Velero is already installed, skip ahead to Part 5 — there's
> nothing to redo here.
>
> Editing this local file **after** Velero is already installed does nothing
> by itself — the running server reads credentials from the
> `cloud-credentials` Secret it already has, not from this file on disk. If
> you need Velero to actually start using a *new* key (e.g. testing with a
> freshly created access key/user), see below.

### Rotating to a new access key on an already-installed Velero

```bash
# 1) Update the local credentials file with the new key/secret
#    (edit velero/credentials-velero directly, or re-run the cp above and re-edit)

# 2) Overwrite the cloud-credentials Secret Velero actually reads from
kubectl -n velero create secret generic cloud-credentials \
  --from-file=cloud=./velero/credentials-velero \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) Restart the Velero deployment so it picks up the new Secret
#    (Velero doesn't hot-reload credentials — the pod needs to restart)
kubectl -n velero rollout restart deployment/velero
kubectl -n velero rollout status deployment/velero

# 4) Confirm the new key actually works
velero backup-location get
# PHASE should read Available; if it flips to Unavailable, the new key/grant
# has a problem — see the bucket-permissions note in Part 4
```

### 4.5 — Run the install

> **Cluster-wide, not per-namespace:** Velero is a single, cluster-wide
> install — one server Deployment in the `velero` namespace, protecting every
> app namespace on the cluster. If Velero is already installed here, skip
> this entire step and go straight to Part 5 for your new namespace; there's
> nothing to reinstall.

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.11.0 \
  --bucket velero \
  --secret-file ./velero/credentials-velero \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=https://objects.ntnxlab.local,insecureSkipTLSVerify=true \
  --use-volume-snapshots=false \
  --features=EnableCSI \
  --namespace velero
```

> **Why `--provider aws` against Nutanix Objects?** `aws` here means "use the
> plugin that speaks the S3 protocol," not "this is really AWS." Nutanix
> Objects exposes the same S3 API, so the AWS-branded plugin works against it
> unmodified — there's no separate "Nutanix" provider plugin, because none is
> needed. This is also why `velero backup-location get` always prints
> `PROVIDER: aws`, even though the actual backend is Nutanix Objects — what
> makes this *not* real AWS is the rest of the config: the custom `s3Url`
> pointing at `objects.ntnxlab.local` instead of `s3.amazonaws.com`,
> `s3ForcePathStyle: true`, and `insecureSkipTLSVerify` for the self-signed cert.

Walking through what each flag actually does, since "just run this" isn't
teaching:

- `--provider aws` — use the S3-protocol object store plugin. Says nothing about
  which cloud you're actually on.
- `--plugins velero/velero-plugin-for-aws:v1.11.0` — the specific plugin image to
  install. This is what implements the S3 API calls.
- `--bucket` / `--secret-file` / `--backup-location-config` — together, these
  become the `BackupStorageLocation` object from Part 3.
- `--use-volume-snapshots=false` — this specifically disables the AWS plugin's
  *native EBS snapshot* mechanism (Option A-for-AWS, irrelevant to us). It's a
  separate switch from CSI snapshotting and easy to confuse — we're not turning
  off volume snapshots overall, just the AWS-specific one we don't need.
- `--features=EnableCSI` — turns on the CSI snapshot code path (Part 2, Option A)
  that we *do* want.
- `--namespace velero` — where the Velero server Deployment, its ServiceAccount,
  and the `cloud-credentials` Secret all land. Convention, not required to be this
  name, but don't fight the convention without a reason.

This command creates, in order: all the Velero CRDs (`Backup`, `Restore`,
`Schedule`, etc.), the `velero` namespace, RBAC, the credentials Secret, the
`BackupStorageLocation`, and finally the Velero server Deployment itself.

### 4.6 — Verify

```bash
kubectl -n velero get pods
velero backup-location get
```

Expected:

```text
NAME                      READY   STATUS    RESTARTS   AGE
velero-75b9b7cb74-59j9n   1/1     Running   0          6h1m
NAME      PROVIDER   BUCKET/PREFIX   PHASE       LAST VALIDATED                  ACCESS MODE   DEFAULT
default   aws        velero          Available   2026-07-30 18:44:45 -0300 -03   ReadWrite     true
```

`PHASE: Available` is what matters — `PROVIDER: aws` is expected too, even
against Nutanix Objects (see the callout above the install command for why).

If it says `Unavailable`, walk the Part 3 gotchas in order — wrong region, wrong
path-style, wrong TLS handling, and (most likely) missing bucket permission grant,
roughly in decreasing order of "confusing error message, boring actual cause."

---

## Part 5 — Your first backup

### The concept (Backup)

A `Backup` is a Kubernetes custom resource — you're not running a `velero backup`
CLI command that does work locally, you're creating an object that the
in-cluster Velero server watches and reconciles, the same reconcile-loop pattern
as everything else in Kubernetes. That matters operationally: backups survive
your laptop closing, and you can `kubectl apply` them from CI/CD or GitOps just
like any other manifest.

### What happens, in order, when you create one

1. Velero's `backup` controller notices the new `Backup` object.
2. It queries the API server for every resource in the included namespace(s) —
   this is the "shape" from Part 1.
3. For each PVC found, if `snapshotVolumes: true`, it creates a `VolumeSnapshot`
   object (the standard Kubernetes CSI API) and waits for the CSI driver to report
   it ready.
4. It **uploads everything** — the resource manifests, plus metadata pointing at
   the storage-level snapshot(s) — to the bucket as a set of compressed files
   under `<bucket>/backups/<backup-name>/`.
5. It **deletes the live `VolumeSnapshot`/`VolumeSnapshotContent` objects** from
   the cluster. This surprised us the first time — `kubectl get volumesnapshot`
   showing nothing right after a "successful" backup looks like a failure but
   isn't. The underlying storage-level snapshot survives because the
   `VolumeSnapshotClass` has `DeletionPolicy: Retain` — only the *Kubernetes
   object pointing at it* gets cleaned up, not the actual snapshot data. Velero
   re-creates the K8s objects from the backup's stored metadata at restore time.
6. Phase flips to `Completed` (or `PartiallyFailed`/`Failed` if something broke).

### Doing it

```yaml
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: scuba-backup-01
  namespace: velero
spec:
  includedNamespaces:
  - miriam-velero
  snapshotVolumes: true
  defaultVolumesToFsBackup: false
  storageLocation: default
  ttl: 720h0m0s
```

```bash
kubectl apply -f velero/backup-scuba.yaml
kubectl -n velero get backup scuba-backup-01 -w    # watch PHASE flip to Completed
velero backup describe scuba-backup-01 --details   # full breakdown
```

> **Note for the demo:** `velero ... describe --details` fetches extra detail
> files directly from the object store's own endpoint, from wherever *you* run
> the CLI. If that hostname only resolves inside the cluster (ours did), running
> `describe` from your laptop shows harmless DNS errors on those specific lines —
> the `Phase: Completed` and item count come from the API server, not that lookup,
> and are what actually matter.

### Inspecting the bucket directly (optional)

Useful when `describe --details` isn't enough, or you're just curious what
Velero actually stored. Since the endpoint only resolves in-cluster, do this
from a throwaway pod with the bucket credentials as env vars, not your laptop:

```bash
ACCESS_KEY=$(grep aws_access_key_id velero/credentials-velero | cut -d= -f2)
SECRET_KEY=$(grep aws_secret_access_key velero/credentials-velero | cut -d= -f2)

kubectl run aws-cli-list-probe -n velero --restart=Never --image=amazon/aws-cli:2.17.0 \
  --overrides="{\"spec\":{\"containers\":[{\"name\":\"aws-cli\",\"image\":\"amazon/aws-cli:2.17.0\",\"command\":[\"sleep\",\"300\"],\"env\":[{\"name\":\"AWS_ACCESS_KEY_ID\",\"value\":\"${ACCESS_KEY}\"},{\"name\":\"AWS_SECRET_ACCESS_KEY\",\"value\":\"${SECRET_KEY}\"}]}]}}"
kubectl wait --for=condition=Ready pod/aws-cli-list-probe -n velero --timeout=60s

kubectl exec -n velero aws-cli-list-probe -- \
  aws --endpoint-url https://objects.ntnxlab.local --no-verify-ssl --region us-east-1 \
  s3 ls s3://velero/ --recursive

kubectl delete pod aws-cli-list-probe -n velero --now
```

Expected: two top-level prefixes, `backups/` and `restores/`. Each backup gets
its own folder (`backups/<backup-name>/`) containing `velero-backup.json` (the
`Backup` object's own metadata), a `.tar.gz` (the actual K8s resource
manifests), and separate gzipped JSON files for logs, the resource list,
volume-snapshot info, and item-operations — exactly the set of files `velero
backup describe --details` reaches for, and why running that command from
your laptop instead of in-cluster fails on those specific lines (the note
above). Restores get a similar but smaller folder under
`restores/<restore-name>/` — logs and resource lists, no new tarball, since a
restore only reads a `Backup`'s existing data rather than producing its own.

---

## Part 6 — Your first restore

### The concept (Restore)

A `Restore` is the mirror image of a `Backup` — another CRD, another
reconcile loop. It reads a chosen `Backup`'s stored data back out of the bucket
and recreates the Kubernetes objects (and, for CSI-snapshotted volumes,
provisions new PVs from the retained storage-level snapshots).

### namespaceMapping — the single setting that turns "restore" into "migrate"

By default, a `Restore` recreates resources in their **original** namespace. If
that namespace still exists with the same resources in it, you'll get conflicts.
`namespaceMapping` tells Velero to recreate everything under a *different*
namespace name instead:

```yaml
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: scuba-restore-01
  namespace: velero
spec:
  backupName: scuba-backup-01
  namespaceMapping:
    miriam-velero: miriam-velero-restored
  restorePVs: true
```

This is *exactly* the mechanism a real cross-cluster migration uses — the only
difference between "restore into a new namespace on the same cluster" (our POC
demo) and "restore onto an entirely different cluster" is which cluster's
`kubectl` context you're pointed at when you `kubectl apply` the `Restore`. The
YAML doesn't change. That equivalence is worth saying out loud to the customer —
it's the whole reason a same-cluster POC is a legitimate way to prove out a
cross-cluster migration story without needing two clusters provisioned yet.

```bash
kubectl apply -f velero/restore-scuba-migrated.yaml
kubectl -n velero get restore scuba-restore-01 -w
velero restore describe scuba-restore-01 --details
kubectl -n miriam-velero-restored get pods,pvc     # should all come up healthy
```

> Same DNS caveat as backup's `describe --details` in Part 5: this fetches
> extra detail files (warnings, resource list, volume info) directly from
> `objects.ntnxlab.local`, **from wherever you run the CLI**. Run it from your
> laptop instead of in-cluster, and those specific lines error with `dial tcp:
> lookup objects.ntnxlab.local: no such host` — harmless. `Phase: Completed`
> plus `Items restored: <N>` matching `Total items to be restored: <N>`,
> printed above all that noise, are what actually confirm success.

Point Helm at the restored release so future `helm upgrade`s work cleanly against
it, instead of treating it as unmanaged:

```bash
helm upgrade --install scuba deploy/charts/scuba-divelog \
  --namespace miriam-velero-restored \
  --force-conflicts
```

> **Why this is needed — verified, not assumed:** Velero restores objects
> *as-is*, annotations included. Check any restored Deployment and you'll find
> it still claims to belong to the **old** namespace:
>
> ```bash
> kubectl -n miriam-velero-restored get deployment scuba-backend \
>   -o jsonpath='{.metadata.annotations}'
> # {"meta.helm.sh/release-name":"scuba","meta.helm.sh/release-namespace":"miriam-velero", ...}
> ```
>
> Same story for the Helm release-history Secret
> (`sh.helm.release.v1.scuba.v1`) — it gets restored into the new namespace
> too, but the release record serialized inside it still says its own
> namespace is `miriam-velero` (`helm list -n miriam-velero-restored` shows
> `NAMESPACE: miriam-velero`, even though you're querying
> `miriam-velero-restored`). So every restored object internally claims to
> belong to a Helm release in a *different* namespace than the one it's
> actually sitting in.
>
> Helm 4 upgrades via Kubernetes server-side apply by default. That old,
> mismatched ownership metadata makes the server-side-apply patch conflict,
> and `--force-conflicts` (`helm upgrade --help`: *"if set server-side apply
> will force changes against conflicts"*) pushes it through anyway — which is
> what re-points every object's ownership at the new namespace and lets plain
> `helm upgrade` work normally from then on. In plain English: **this command
> is what lets Helm take over management of the restored resources.**
>
> Don't confuse this with the separate `--force-replace` flag ("force resource
> updates by replacement") — that one deletes and recreates resources instead
> of patching them. We don't need that here; the objects are already correct,
> only their ownership metadata needs fixing.

### Two things that will look broken but aren't, in a same-cluster demo

- **SealedSecrets (if your app uses them) show `SYNCED: False` after restore.**
  This is app-specific, not a Velero behavior, but customers hit it constantly:
  if secrets are managed by a namespace-scoped encryption controller (like
  Bitnami's Sealed Secrets), the *encrypted* `SealedSecret` object can't decrypt
  in a namespace it wasn't sealed for. Doesn't matter for the demo — the actual
  plain `Secret` objects (already decrypted, with real data) get restored
  directly by Velero and keep working; only the sealed-secrets controller's
  attempt to *re-derive* them fails, silently and harmlessly.
- **Two ingresses claiming the same hostname.** If both the original and restored
  namespace deploy an Ingress for the same host, only one gets traffic from the
  shared ingress controller. Not a Velero problem — it's what happens whenever you
  duplicate an app on one cluster. `kubectl -n <restored-ns> port-forward` bypasses
  this cleanly for verification purposes.

### Showing the customer both copies side by side

Because of the ingress collision above, port-forward is the reliable way to
demo this: original (untouched — proves Velero doesn't disrupt production) and
restored (proves the backup/restore actually worked), open at the same time in
two browser tabs.

```bash
# Original app — still running, never touched by the backup/restore
kubectl -n miriam-velero port-forward svc/scuba-frontend 18080:80 &
# -> http://localhost:18080/

# Restored app — proves the migration worked
kubectl -n miriam-velero-restored port-forward svc/scuba-frontend 18081:80 &
# -> http://localhost:18081/
```

Stop both afterward with `pkill -f "port-forward svc/scuba-frontend"`.

### Taking this cross-cluster for real

Nothing above is actually same-cluster-specific — repeat here what was said
earlier: the `Restore` YAML doesn't change for a genuine cross-cluster migration,
only which cluster's `kubectl` context is active when you apply it. Concretely:

```bash
# On the SECOND cluster, pointed at the SAME Nutanix Objects bucket:
kubectl config use-context <second-cluster-context>

# Repeat Part 4 there (sealed-secrets controller if needed, VolumeSnapshotClass
# label, credentials file, velero install) against the same bucket/endpoint —
# Velero itself has no cross-cluster state, each cluster runs its own server.

velero backup get
# scuba-backup-01 should already be listed — it's visible because both
# clusters' Velero servers point at the same bucket, not because of any
# direct link between the clusters themselves.

# Edit restore-scuba-migrated.yaml first: remove namespaceMapping entirely,
# since this is now a different cluster, not a namespace collision to avoid.
kubectl apply -f velero/restore-scuba-migrated.yaml
```

> **Why omitting `namespaceMapping` is enough — no explicit target namespace
> needed:** for any source namespace *not* listed in `namespaceMapping`,
> Velero restores its resources into a namespace of the **same name** it had
> at backup time — read from each object's own `metadata.namespace`, not from
> the current `kubectl` context or any flag on the restore command. Since our
> backup backed up `miriam-velero`, dropping `namespaceMapping` restores
> everything into a namespace literally called `miriam-velero` on the second
> cluster (created automatically if it doesn't already exist there) — exactly
> what a real migration wants. Explicitly mapping `miriam-velero` →
> `miriam-velero` would produce the identical result; it's a no-op, not a real
> alternative.

---

## Part 7 — Automating it: Schedules

### The concept (Schedule)

A `Schedule` is a cron-triggered `Backup` factory — it doesn't run backups
itself, it creates new `Backup` objects on a timer, each one built from the same
template you'd otherwise hand-write. Same reconcile-loop pattern as everything
else here.

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: scuba-daily
  namespace: velero
spec:
  schedule: "0 2 * * *"
  template:
    includedNamespaces:
    - miriam-velero
    snapshotVolumes: true
    defaultVolumesToFsBackup: false
    storageLocation: default
    ttl: 168h0m0s
```

### Cron syntax, taught simply

`spec.schedule` is standard 5-field cron:

```text
 ┌───────────── minute (0–59)
 │ ┌───────────── hour (0–23)
 │ │ ┌───────────── day of month (1–31)
 │ │ │ ┌───────────── month (1–12)
 │ │ │ │ ┌───────────── day of week (0–6, Sunday=0)
 │ │ │ │ │
 * * * * *
```

`*` means "match anything" in that slot — so it's really just five yes/no
questions: *which minute, which hour, which day of month, which month, which
weekday should this fire?* `0 2 * * *` = minute 0, hour 2, any day, any month,
any weekday → **02:00 every day**.

Three symbols cover almost every real schedule you'll write:

| Symbol | Meaning | Example |
| --- | --- | --- |
| `*/N` | every N units | `*/15 * * * *` = every 15 minutes |
| `A-B` | a range | `0 2 * * 1-5` = 2am, Mon–Fri only |
| `A,B,C` | a list | `0 2 * * 1,3,5` = 2am, Mon/Wed/Fri only |

| Goal | Cron | What it does |
| --- | --- | --- |
| Every hour | `0 * * * *` | Runs once every hour, on the hour |
| Every 6 hours | `0 */6 * * *` | Runs 4x/day, 6 hours apart |
| Once a day | `0 2 * * *` | What `scuba-daily` uses |
| Weekdays only | `0 2 * * 1-5` | Skips Sat/Sun |
| Once a week | `0 2 * * 0` | Sundays only |
| Once a month | `0 2 1 * *` | 1st of the month only |

The minimum granularity is one minute (`* * * * *`) — cron has no sub-minute
field. In practice you'd never actually schedule that frequently; each run is a
full CSI-snapshot-plus-upload cycle, not a lightweight poll.

### Retention: ttl is time-based, not count-based

This trips up almost everyone coming from backup tools that let you say "keep the
last 7 copies." **Velero has no such setting.** Retention is purely
`spec.ttl` (a Go duration, e.g. `168h0m0s`) on each `Backup`; Velero's garbage
collector deletes backups once their `ttl` expires, on its own periodic sweep
(not instantly at the exact expiry second).

To *approximate* "keep the last N backups," derive `ttl` from your schedule's
frequency: `ttl = interval × N`. Daily backups, want to keep a week's worth →
`168h` (7 days). It's an approximation, not a guarantee — a missed or failed run
means you'll have fewer than N on hand; an unusually long gap between runs could
briefly leave more. If a customer needs an *exact* count guarantee, that requires
a separate scripted job (`velero backup get -l velero.io/schedule-name=<name>`,
sort by age, `velero backup delete` anything past the Nth-newest) — worth
mentioning as a known gap, not something to silently promise.

```bash
kubectl apply -f velero/schedule-scuba.yaml
velero schedule get                                # STATUS: Enabled
velero backup create --from-schedule scuba-daily    # trigger one immediately, don't wait for 2am

# List every backup this schedule (or any other) has produced, and check STATUS
velero backup get
# NAME                        STATUS      ERRORS   WARNINGS   CREATED   EXPIRES   STORAGE LOCATION   SELECTOR
# scuba-daily-20260731020000  Completed   0        0          ...       ...       default            <none>
# STATUS should read Completed; PartiallyFailed/Failed means something in that
# specific run broke — kubectl -n velero logs deployment/velero around that
# timestamp, or velero backup describe <name> --details, for why
```

---

## Part 8 — Reading failures like Velero intends you to

Three commands cover almost every troubleshooting session:

```bash
velero backup-location get              # is the object store reachable/authorized at all?
velero backup describe <name> --details # what happened during THIS backup specifically
kubectl -n velero logs deployment/velero # the server's own log stream, for anything the above doesn't explain
```

A mental model for triaging what you see:

- **`BackupStorageLocation` itself is `Unavailable`** → this is an object-store
  connectivity/config problem (Part 3's four gotchas), not a Velero logic bug.
  Nothing backup-specific will work until this says `Available`.
- **BSL is `Available`, but a specific `Backup` is `PartiallyFailed`** → usually a
  volume-snapshot-specific issue (wrong/missing `VolumeSnapshotClass` label,
  CSI driver hiccup) rather than an object-store issue — the manifest upload
  succeeded, the volume snapshot step didn't.
- **`Restore` fails with "resource already exists"** → not a Velero bug, it's
  telling you the target namespace already has conflicting objects (an old Helm
  release, a previous restore attempt). Clean up first, or accept the conflict
  resolution Velero offers.

Concrete symptom → cause → fix, for the specific failures we actually hit setting
this up:

| Symptom | Cause | Fix |
| --- | --- | --- |
| BSL `PHASE: Unavailable` | Bad endpoint/creds, or path-style not set | Check `velero/credentials-velero`, confirm `s3ForcePathStyle: "true"`, check `s3Url` |
| BSL `PHASE: Unavailable`, TLS error in server logs | Self-signed/internal CA cert | Add `insecureSkipTLSVerify: "true"` to the BSL config |
| BSL `PHASE: Unavailable`, `IllegalLocationConstraintException` | Wrong `region` value | Use the object store's actual configured region (commonly `us-east-1`) |
| BSL `PHASE: Unavailable`, `AccessDenied` on list/head calls | Key is valid but not granted access to this bucket | Grant the key's user explicit permission on the bucket in the Objects console |
| Backup `Phase: PartiallyFailed`, PVC snapshot errors | `VolumeSnapshotClass` missing the Velero label | Re-run the `kubectl label volumesnapshotclass ... velero.io/csi-volumesnapshot-class=true` command |
| Restore fails: "namespace already exists with resources" | Target namespace already has a conflicting release | Delete the namespace before restoring, or use `--force-conflicts` on the following `helm upgrade --install` |
| `velero install` pods stuck `ImagePullBackOff` | No internet egress to Docker Hub | Mirror the plugin image into an internal registry and reference it in `--plugins` |

---

## Part 9 — Talking to the customer about production, not just the POC

A POC proves the mechanism works. Before calling it done, walk the customer
through what changes for a real rollout — these are talking points, not something
this POC needs to implement:

- **Test restores regularly, not just once.** A backup nobody has ever restored
  from is a hypothesis, not a safety net. Recommend a periodic (e.g. monthly)
  restore drill into a scratch namespace, exactly like Part 6's demo.
- **Don't disable TLS verification in production.** `insecureSkipTLSVerify` was a
  POC convenience for a self-signed cert; production should trust the internal CA
  properly instead.
- **Credentials hygiene.** The access key used here has write access to one
  bucket. Rotate it, don't reuse it for anything else, and keep the plaintext
  credentials file out of git (as we did) and out of the backup's own scope.
- **Retention is a business decision, not a technical default.** `ttl` should map
  to an actual recovery-point objective the customer has agreed to, not whatever
  number was convenient during the POC.
- **One `BackupStorageLocation` is a single point of failure for backups
  themselves.** Larger environments often configure a second BSL in a different
  bucket/region as a belt-and-suspenders measure — worth raising, not necessarily
  building, during a POC.

---

## Where to go next

- [`runbook-velero.md`](./runbook-velero.md) — same commands, no narration, for
  once you already know this material and just want the copy-paste reference.
- Velero's own docs (<https://velero.io/docs/>) for anything provider-specific
  beyond what this guide covers — the CSI/object-store fundamentals here apply
  everywhere, but plugin version compatibility matrices change over time and are
  worth checking against whatever Velero version you're actually installing.
