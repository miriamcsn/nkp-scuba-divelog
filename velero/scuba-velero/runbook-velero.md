# Velero POC Runbook — scuba app migration

Same `scuba` app used by the NDK-based DR setup in [`ndk/`](../ndk) (that setup
runs on a separate pair of clusters, `nkp-wlc-a`/`nkp-wlc-b`, and isn't installed
here) — backed up with Velero (CSI snapshots via the Nutanix CSI driver) into
Nutanix Objects (S3-compatible), then restored. For this POC it runs on the
**`it-cluster`** workload cluster, into a different namespace on the same cluster
(`miriam-velero` → `miriam-velero-restored`), to prove the mechanism before
pointing a second cluster at the same bucket for a real cross-cluster migration.

## Prerequisites checklist

Grab/confirm all of this **before** starting step 1 — most of the friction in the
first run of this runbook came from discovering these one at a time mid-procedure.
Every check below is: run this command → compare to expected output → if it
doesn't match, do the fix.

### Local tools

**`kubectl`**

```bash
kubectl version --client
```

Expected: a version block with no errors, e.g. `Client Version: v1.29.x`.
If missing: install it (`brew install kubectl` on macOS, or your platform's
package manager / the Kubernetes docs).

**`helm`** (installs sealed-secrets and the scuba chart)

```bash
helm version
```

Expected: `version.BuildInfo{Version:"v3.x.x", ...}`.
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

**`kubeseal` CLI** (only needed if you'll reseal secrets yourself, step 1)

```bash
kubeseal --version
```

Expected: `kubeseal version: v0.2x.x`.
If missing: `brew install kubeseal`.

### Cluster access

**Correct context selected** — critical if contexts are named ambiguously (ours
are IP-only, `wonderful_fermi-<ip>`, for both the management cluster and every
workload cluster it manages):

```bash
kubectl config get-contexts
kubectl config use-context <your-workload-cluster-context>
kubectl get nodes
```

Expected: a list of `Ready` nodes whose **names** identify the cluster you meant
to target (e.g. `it-cluster-...`), not the management cluster.
If wrong cluster: `kubectl config use-context <correct-context>` and re-check —
don't proceed until the node names confirm you're in the right place.

**CSI driver + VolumeSnapshotClass already exist** (Velero doesn't install
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

If either returns nothing: CSI snapshotting isn't configured on this cluster —
that's infrastructure the customer's storage admin needs to set up first, not
something fixable from the Velero side. (Fallback: Velero's File System Backup
mode works without CSI snapshot support at all, at the cost of slower
backups/restores — see `velero-setup.md` Part 2 if that's the only option.)

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
complete oddly since `velero`'s image isn't meant to run standalone with `true`
as an override — that part doesn't matter, only the pull event does).
If it hangs in `ImagePullBackOff` with no successful pull event: no egress —
you'll need an internal registry mirror and must reference the mirrored image
paths in `--plugins` at install time (step 4).

### Nutanix Objects (S3-compatible backup target)

These four values come from whoever manages Prism Central — don't guess them,
each wrong guess produces a *different*, equally-confusing error:

- [ ] Bucket name (already provisioned — e.g. `velero`)
- [ ] Object Store endpoint/FQDN (e.g. `objects.ntnxlab.local`) — the *base*
  endpoint, not a bucket-prefixed virtual-hosted-style hostname
- [ ] Region string configured for that store — commonly `us-east-1` even
  on-prem, but confirm; a mismatch fails with a cryptic
  `IllegalLocationConstraintException`, not an auth error
- [ ] Access key + secret key for a user, **and confirmation that user has been
  explicitly granted access to that specific bucket** — a valid key pair alone
  isn't enough in Nutanix Objects; bucket access is a separate policy grant, and
  the failure mode (`AccessDenied`) looks identical whether the key is wrong or
  just unauthorized on this bucket

Once you have all four, verify the endpoint itself **before** running `velero
install` — catches DNS/addressing-style/TLS problems early instead of buried in
a `velero` server log. If the hostname is internal-only (ours was), run this
from a throwaway pod, not your laptop:

```bash
kubectl run objects-check --image=curlimages/curl:8.10.1 --restart=Never --rm -it -- \
  curl -sk -o /dev/null -w "HTTP %{http_code}\n" https://<endpoint>/<bucket>/
```

Expected: `HTTP 403` — this is a **good** sign here, it means the server
answered with a real S3 `AccessDenied` response, confirming the endpoint,
hostname, and path-style addressing all work; you just haven't authenticated
yet, which is expected for this quick check.
If it hangs/times out/`curl: (6) Could not resolve host`: wrong endpoint, or
you need to run this from inside the cluster instead of your laptop (internal
DNS names often don't resolve externally) — don't move on to `velero install`
until this resolves and answers.
If it errors on the TLS handshake (`curl: (60)`): self-signed/internal CA cert
— note that down, you'll need `insecureSkipTLSVerify: "true"` in step 4.

### App-specific (scuba chart)

- [ ] Namespace name(s) decided ahead of time (app namespace + restore-target
  namespace if testing migration on the same cluster)
- [ ] Aware that `mysql-secret.yaml`/`backend-db-secret.yaml` are `SealedSecret`s
  scoped to one cluster+namespace — on any new namespace, the sealed-secrets
  controller must be installed and those secrets resealed for it (step 1), even if
  both already exist elsewhere

---

## Cluster

`it-cluster` is a workload cluster managed by the management cluster
(`wonderful_fermi-10.55.86.135`), reachable directly at its own API endpoint.
Both clusters' kubeconfig contexts are named by IP only (`wonderful_fermi-<ip>`),
so pick the right one explicitly before running anything below:

```bash
kubectl config get-contexts
kubectl config use-context wonderful_fermi-10.55.86.149   # it-cluster's own API endpoint

# Confirm you're on it-cluster, not the mgmt cluster:
kubectl get nodes
# node names should be prefixed "it-cluster-..."
```

## Namespaces

| Cluster | App runs here | Velero server runs here |
| --- | --- | --- |
| `it-cluster` (`wonderful_fermi-10.55.86.149`) | `miriam-velero` | `velero` |
| restore target (same cluster, this POC) | `miriam-velero-restored` | — |

## Confirmed on it-cluster

Result of running through the [Prerequisites checklist](#prerequisites-checklist)
above on this specific cluster — a quick-reference, not a substitute for
re-running the checks yourself on a fresh namespace/customer environment:

- `velero` CLI v1.18.x, `kubectl`, `helm`, `kubeseal` all present locally
- Storage class `nutanix-volume` (default), provisioner `csi.nutanix.com`
- `VolumeSnapshotClass` `nutanix-snapshot-class` exists (not yet labeled for
  Velero — that's step 2)
- Outbound internet egress to Docker Hub confirmed working, no internal
  registry mirror needed

---

## 1. Create the app namespace and deploy scuba

The chart's `mysql-secret.yaml` and `backend-db-secret.yaml` templates are
`SealedSecret`s (see [`docs/gitops-setup.md`](../docs/gitops-setup.md)) — they
only decrypt for the namespace + sealed-secrets controller they were sealed
against, and the committed blobs were sealed for a different cluster/namespace.
On a brand-new cluster/namespace, install the controller and reseal first:

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets   # no-op if already added
helm repo update sealed-secrets

helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace sealed-secrets --create-namespace --wait --timeout 3m

kubectl create namespace miriam-velero

# Reseal for THIS namespace. MYSQL_DATABASE/MYSQL_ROOT_PASSWORD are pinned here
# so they match scripts/seed-scuba-v3.sh's defaults (DB=divelog, ROOT_PW=rootpw) —
# reseal-secrets.sh's own default is MYSQL_DATABASE=scubadb, which the seed
# script doesn't know about, so leaving it unset would break seeding.
NAMESPACE=miriam-velero MYSQL_DATABASE=divelog MYSQL_ROOT_PASSWORD=rootpw \
  ./scripts/reseal-secrets.sh
# note the generated mysql password it prints — needed only if you query MySQL
# directly as the app user; root access (used below) doesn't need it
```

```bash
helm install scuba deploy/charts/scuba-divelog --namespace miriam-velero
kubectl -n miriam-velero get pods -w
```

Seed some data so the backup/restore has something to prove:

```bash
NAMESPACE=miriam-velero ./scripts/seed-scuba-v3.sh
```

## 2. Make the existing VolumeSnapshotClass usable by Velero's CSI support

Velero's built-in CSI plugin (native since Velero v1.14, enabled via
`--features=EnableCSI` at install — no separate plugin image needed) only uses
`VolumeSnapshotClass` objects labeled `velero.io/csi-volumesnapshot-class: "true"`.
There's already one for the Nutanix CSI driver on this cluster:

```bash
kubectl get volumesnapshotclass
# NAME                     DRIVER            DELETIONPOLICY   AGE
# nutanix-snapshot-class   csi.nutanix.com   Retain           ...
```

Label it (additive — doesn't change how anything else that uses it behaves):

```bash
kubectl label volumesnapshotclass nutanix-snapshot-class \
  velero.io/csi-volumesnapshot-class=true
```

Expected: `volumesnapshotclass.snapshot.storage.k8s.io/nutanix-snapshot-class labeled`.

> **Cluster-wide, not per-namespace:** `VolumeSnapshotClass` is a cluster-scoped
> resource, not namespaced — so this only needs to run **once per cluster**, not
> once per app/namespace. If you've already run this runbook once on this
> cluster and are now repeating it for a new namespace, you'll instead see
> `volumesnapshotclass.snapshot.storage.k8s.io/nutanix-snapshot-class not
> labeled` — that's not an error, it means the label is already there from last
> time (`kubectl label` without `--overwrite` prints "not labeled" when the
> requested label:value already matches, i.e. nothing needed to change). Verify
> with `kubectl get volumesnapshotclass nutanix-snapshot-class --show-labels`
> and move on to step 3.

## 3. Set up S3 credentials for Nutanix Objects

```bash
cp velero/credentials-velero.example velero/credentials-velero
# edit velero/credentials-velero and fill in the real access key / secret key
# (this file is gitignored — never commit it)
```

This copies the **template** file (`velero/credentials-velero.example`, tracked
in git, placeholder values only) to a **real** file
(`velero/credentials-velero`, gitignored) that you then edit with your actual
access key and secret key. `velero install` (step 4) reads this file once, to
create the `cloud-credentials` Secret the running Velero server actually
authenticates with.

> **Cluster-wide, not per-namespace** (same idea as step 2's label): Velero is
> installed once per cluster, so this file only needs to be created/filled in
> once per cluster too — not once per app/namespace. If you're repeating this
> runbook for a new namespace on a cluster where Velero is already installed,
> skip ahead to step 5; there's nothing to redo here.
>
> Editing this local file **after** Velero is already installed does nothing by
> itself — the running server reads credentials from the `cloud-credentials`
> Secret it already has, not from this file on your disk. If you need Velero to
> actually start using a *new* key (e.g. testing with a freshly created access
> key/user), see below.

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
# has a problem — see the bucket-permissions note in step 4
```

Endpoint notes (verified from inside `it-cluster` with throwaway curl/aws-cli pods):

- `objects.ntnxlab.local` resolves and answers S3 requests; `velero.objects.ntnxlab.local`
  (virtual-hosted style) does **not** resolve — path-style is required, not optional.
- `objects.ntnxlab.local` presents a self-signed/internal CA cert (`curl` fails without
  `-k`) — `insecureSkipTLSVerify` must be set.
- Path-style request to the bucket (`https://objects.ntnxlab.local/velero/`) returns a
  proper S3 `AccessDenied` XML response unauthenticated — confirms the `velero` bucket
  exists at this endpoint.
- **Region must be `us-east-1`**, not an arbitrary placeholder. `region=default` fails
  BSL validation with `IllegalLocationConstraintException`; `region=us-east-1` clears
  that error (confirmed via a signed `aws s3api list-objects-v2` call from an in-cluster
  aws-cli pod), even though this is on-prem, not AWS — the S3-compatible API still
  validates the signing region against the bucket's configured region.

## 4. Install Velero

> **Cluster-wide, not per-namespace** (same idea as steps 2 and 3): Velero is a
> single, cluster-wide install — one server Deployment in the `velero`
> namespace, protecting every app namespace on the cluster. If Velero is
> already installed here, skip this entire step and go straight to step 5 for
> your new namespace; there's nothing to reinstall.

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
>
> **Bucket permissions:** if `velero backup-location get` shows `PHASE: Unavailable`
> with `AccessDenied` on `ListObjectsV2`/`HeadBucket` in `kubectl -n velero logs
> deployment/velero`, the access key's user hasn't been granted access to the
> `velero` bucket in Nutanix Objects yet (a valid key alone isn't enough — this is a
> separate bucket-level policy grant). Fix in Prism Central → Buckets → `velero` →
> permissions, then re-check `velero backup-location get`; no Velero-side config
> changes needed once the grant is in place.
>
> `--use-volume-snapshots=false` because we're using CSI snapshots (step 2), not
> the AWS-plugin's native EBS `VolumeSnapshotLocation` mechanism — that flag is
> for a different snapshotting path we don't need here.

Verify:

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

`velero/backup-storage-location.yaml` is a reference copy of what this install
command produces — kept in git so the S3-compatible config is visible without
having to re-derive the install flags.

## 5. Back up the scuba app

```bash
kubectl apply -f velero/backup-scuba.yaml
velero backup describe scuba-backup-01 --details
# wait for Phase: Completed
```

> `velero ... describe --details` fetches extra detail files (warnings, resource
> list, volume info) directly from `objects.ntnxlab.local` **from wherever you run
> the CLI** — if that's your laptop rather than inside the cluster, those specific
> lines error with `dial tcp: lookup objects.ntnxlab.local: no such host` (that
> hostname only resolves in-cluster). Harmless — `Phase: Completed` and the
> items-backed-up count are what actually matter and come from the API server, not
> that lookup.
>
> The backup's CSI flow creates a `VolumeSnapshot`/`VolumeSnapshotContent` for the
> MySQL PVC, captures their metadata, then **deletes the live K8s objects** —
> `kubectl get volumesnapshot` showing nothing afterward is expected, not a failure.
> The underlying storage-level snapshot survives because `nutanix-snapshot-class`
> has `DeletionPolicy: Retain`; check `kubectl -n velero logs deployment/velero` for
> the "Deleted VolumeSnapshot ... and VolumeSnapshotContent ..." line to confirm it
> ran, if in doubt.

## 5b. Schedule daily backups (optional)

`velero/schedule-scuba.yaml` is a `Schedule` — same spec as `backup-scuba.yaml`
(CSI snapshots, `miriam-velero`), but cron-triggered instead of one-off. Each run
creates a `Backup` named `scuba-daily-<timestamp>`; Velero garbage-collects backups
past their `ttl` automatically.

### Cron syntax, in plain English

`spec.schedule` (`0 2 * * *` for `scuba-daily`) is standard 5-field cron — five
slots, always in this order:

```text
 ┌───────────── minute (0–59)
 │ ┌───────────── hour (0–23)
 │ │ ┌───────────── day of month (1–31)
 │ │ │ ┌───────────── month (1–12)
 │ │ │ │ ┌───────────── day of week (0–6, Sunday=0)
 │ │ │ │ │
 * * * * *
```

`*` means "don't care, match anything" in that slot. So `0 2 * * *` reads as:
minute **0**, hour **2**, any day of month, any month, any day of week →
**02:00, every day.**

Three other symbols cover most real-world schedules:

- `*/N` = every N units — `*/15 * * * *` = every 15 minutes
- `A-B` = a range — `0 2 * * 1-5` = 02:00, Monday through Friday only
- `A,B,C` = a list — `0 2 * * 1,3,5` = 02:00 on Mon/Wed/Fri only

Cheat sheet for customer walkthroughs:

| Goal | Cron | What it does |
| --- | --- | --- |
| Every minute | `* * * * *` | Runs nonstop, once a minute (illustration only — too frequent for real backups) |
| Every hour | `0 * * * *` | Runs once every hour, right when the clock hits :00 |
| Every 6 hours | `0 */6 * * *` | Runs 4 times a day, 6 hours apart (e.g. 12am, 6am, 12pm, 6pm) |
| Once a day | `0 2 * * *` | Runs once every day at 2am — what `scuba-daily` uses |
| Weekdays only | `0 2 * * 1-5` | Runs at 2am, but skips Saturday and Sunday |
| Once a week | `0 2 * * 0` | Runs at 2am, only on Sundays |
| Once a month | `0 2 1 * *` | Runs at 2am, only on the 1st of the month |

`ttl` is set to `168h0m0s` (7 days) to approximate "keep the last 7 backups" —
Velero has no native count-based retention (`keep last N`), only time-based `ttl`,
so `ttl = schedule interval × desired count` is the standard approximation (daily
runs × 7 days). It's not an exact count — a missed/failed run means fewer than 7
on hand; an unusually long gap between runs could briefly leave more. For an exact
count, you'd need a separate scripted job calling `velero backup delete` on
anything past the Nth-newest — not set up here.

```bash
kubectl apply -f velero/schedule-scuba.yaml
velero schedule get
# STATUS should be Enabled; LAST BACKUP populates after the first scheduled run
```

Currently applied on `it-cluster`: `scuba-daily`, `0 2 * * *` (02:00 daily), `ttl: 168h0m0s`.

```bash
# Trigger an ad-hoc run immediately instead of waiting for the schedule
velero backup create --from-schedule scuba-daily

# List every backup this schedule (or any other) has produced, and check PHASE
velero backup get
# NAME                        STATUS      ERRORS   WARNINGS   CREATED   EXPIRES   STORAGE LOCATION   SELECTOR
# scuba-daily-20260731020000  Completed   0        0          ...       ...       default            <none>
# STATUS should read Completed; PartiallyFailed/Failed means something in that
# specific run broke — kubectl -n velero logs deployment/velero around that
# timestamp, or velero backup describe <name> --details, for why

# Pause / resume without deleting the Schedule object
velero schedule pause scuba-daily
velero schedule unpause scuba-daily

# Remove it (does not delete backups already taken)
kubectl delete -f velero/schedule-scuba.yaml
```

## 5c. Inspecting the bucket directly (optional)

Useful when `velero backup describe --details` isn't enough, or you're just
curious what Velero actually stored. Since `objects.ntnxlab.local` only
resolves in-cluster, do this from a throwaway pod with the bucket credentials
as env vars, not your laptop:

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
volume-snapshot info, and item-operations — this is exactly the set of files
`velero backup describe --details` reaches for, and why running that command
from your laptop instead of in-cluster fails on those specific lines (see the
DNS note in step 5). Restores get a similar but smaller folder under
`restores/<restore-name>/` — logs and resource lists, no new tarball, since a
restore only reads a `Backup`'s existing data rather than producing its own.

## 6. Restore into a new namespace (POC stand-in for migration)

```bash
kubectl apply -f velero/restore-scuba-migrated.yaml
velero restore describe scuba-restore-01 --details
# wait for Phase: Completed

kubectl -n miriam-velero-restored get pods,pvc
```

> Same as `velero backup describe --details` in step 5: `velero restore
> describe --details` fetches extra detail files (warnings, resource list,
> volume info) directly from `objects.ntnxlab.local` **from wherever you run
> the CLI**. Run it from your laptop instead of in-cluster, and those specific
> lines error with `dial tcp: lookup objects.ntnxlab.local: no such host` (that
> hostname only resolves in-cluster) — harmless. `Phase: Completed` plus
> `Items restored: <N>` matching `Total items to be restored: <N>`, printed
> above all that noise, are what actually confirm success.

Point `helm` at the restored release so future upgrades work cleanly:

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
> `helm` here is v4, which upgrades via Kubernetes server-side apply by
> default. That old, mismatched ownership metadata makes the server-side-apply
> patch conflict, and `--force-conflicts` (`helm upgrade --help`: *"if set
> server-side apply will force changes against conflicts"*) pushes it through
> anyway — which is what re-points every object's ownership at the new
> namespace and lets plain `helm upgrade` work normally from then on. In plain
> English: **this command is what lets Helm take over management of the
> restored resources.**
>
> Don't confuse this with the separate `--force-replace` flag ("force resource
> updates by replacement") — that one deletes and recreates resources instead
> of patching them. We don't need that here; the objects are already correct,
> only their ownership metadata needs fixing.

Two things to expect, both harmless for this same-cluster POC:

- **`SealedSecret`s show `SYNCED: False`** (`no key could decrypt secret`) after
  restore — they're still scoped to `miriam-velero`, not `miriam-velero-restored`.
  Doesn't matter: the plain `Secret`s they manage (`scuba-mysql`, `scuba-app-db`)
  are restored directly by Velero with their real decrypted data intact, and the
  sealed-secrets controller failing to re-derive them doesn't touch/overwrite the
  already-correct `Secret`. Confirmed the app reads real data fine despite this.
  (On a genuine second-cluster restore, reseal for the target namespace as in step 1
  instead of relying on this.)
- **Ingress host collision**: both `miriam-velero/scuba` and
  `miriam-velero-restored/scuba` request the same host (`scubadivelog.online`) on
  the same `kommander-traefik` controller — only one namespace's ingress actually
  gets traffic for that hostname. To verify the restored copy specifically, bypass
  ingress and hit its Service directly:

  ```bash
  kubectl -n miriam-velero-restored port-forward svc/scuba-backend 18000:8000
  curl http://localhost:18000/sites   # should match the seeded data
  ```

  For a real side-by-side demo, edit `ingress.host` in one namespace's Helm values
  (e.g. `helm upgrade --set ingress.host=scubadivelog-restored.online ...`) so both
  ingresses can serve traffic concurrently.

## Demo: view both instances side by side

> **Currently running this session** — both port-forwards below are already up in
> the background:
>
> - Original (`miriam-velero`) → <http://localhost:18080/>
> - Restored (`miriam-velero-restored`) → <http://localhost:18081/>
>
> Stop them with: `pkill -f "port-forward svc/scuba-frontend"`

Because of the ingress host collision above, port-forward is the reliable way to
show a customer both instances at once — original (untouched, proving Velero
doesn't disrupt production) and restored (proving the backup/restore actually
worked). Run both in separate terminals (or background both with `&`), then open
each URL in the browser:

```bash
# 1) Original app in miriam-velero — still running, never touched by the backup/restore
kubectl -n miriam-velero port-forward svc/scuba-frontend 18080:80
# -> http://localhost:18080/

# 2) Restored app in miriam-velero-restored — proves the migration worked
kubectl -n miriam-velero-restored port-forward svc/scuba-frontend 18081:80
# -> http://localhost:18081/
```

Quick non-interactive check of both (status code + confirm they're serving the same
seeded data):

```bash
for ns_port in "miriam-velero:18080" "miriam-velero-restored:18081"; do
  ns="${ns_port%%:*}"; port="${ns_port##*:}"
  kubectl -n "$ns" port-forward svc/scuba-frontend "$port:80" >/dev/null 2>&1 &
  pf_pid=$!
  sleep 3
  echo "=== $ns (localhost:$port) ==="
  curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://localhost:$port/"
  kill "$pf_pid" 2>/dev/null
done
```

## Going cross-cluster for real

`backup-scuba.yaml` and `restore-scuba-migrated.yaml` don't change for an actual
cross-cluster migration — install Velero on the second cluster pointed at the
*same* bucket (steps 2–4), then on the target cluster apply a Restore that omits
`namespaceMapping` entirely once the source backup shows up:

```bash
export KUBECONFIG=<second-cluster-kubeconfig>
velero backup get                 # confirm scuba-backup-01 is visible (same bucket)
kubectl apply -f velero/restore-scuba-migrated.yaml   # remove namespaceMapping first
```

> **Why omitting it is enough — no explicit target namespace needed:** for any
> source namespace *not* listed in `namespaceMapping`, Velero restores its
> resources into a namespace of the **same name** it had at backup time — read
> from each object's own `metadata.namespace`, not from the current `kubectl`
> context or any flag on the restore command. Since `backup-scuba.yaml` backed
> up `miriam-velero`, dropping `namespaceMapping` restores everything into a
> namespace literally called `miriam-velero` on the second cluster (created
> automatically if it doesn't already exist there) — which is exactly what a
> real migration wants. Explicitly mapping `miriam-velero` → `miriam-velero`
> would produce the identical result; it's a no-op, not a real alternative.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| BSL `PHASE: Unavailable` | Bad endpoint/creds, or path-style not set | Check `velero/credentials-velero`, confirm `s3ForcePathStyle: "true"`, check `s3Url` |
| BSL `PHASE: Unavailable`, TLS error in `velero server` logs | Nutanix Objects using a self-signed/internal CA | Add `insecureSkipTLSVerify: "true"` to the BSL config |
| Backup `Phase: PartiallyFailed`, PVC snapshot errors | `nutanix-snapshot-class` missing the Velero label | Re-run the `kubectl label volumesnapshotclass` command in step 2 |
| Restore fails: "namespace already exists with resources" | Target namespace already has a conflicting release | `kubectl delete namespace miriam-velero-restored` before restoring, or use `--force-conflicts` on the following `helm upgrade --install` |
| `velero install` pods stuck `ImagePullBackOff` | No internet egress to Docker Hub for the plugin image (not expected on `it-cluster` — egress confirmed working) | Mirror `velero/velero-plugin-for-aws` into an internal registry (e.g. the `registry-system` CNCF distribution registry already running here) and reference it in `--plugins` |
