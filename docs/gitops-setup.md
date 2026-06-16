# GitOps CD with Flux — scuba dive-log

This replaces the old push-based deploy job (a self-hosted runner on the cluster
bastion running `helm upgrade`) with **pull-based GitOps**. Flux runs *inside* the
demo cluster, watches this repo, and reconciles the app. Nothing needs inbound
access to the cluster — ideal for an internal-network cluster.

## How it works

```
  push app code ──► GitHub Actions (build job)
                      builds backend + frontend images
                      tags them  main-<unix-ts>-<sha>  and  :latest
                      pushes to ghcr.io/miriamcsn/*
                                   │
                                   ▼
  Flux image-reflector scans GHCR every 5m, sees the newer tag
                                   │
                                   ▼
  Flux image-automation rewrites the tag in clusters/demo/scuba-helmrelease.yaml
  and git-commits + pushes to main  (commit author: fluxcdbot)
                                   │
                                   ▼
  Flux source + helm controllers reconcile the HelmRelease
                                   │
                                   ▼
  scuba app rolls out in namespace miriam-nkp-demo
```

The CI workflow ignores pushes that only touch `clusters/**`, `docs/**`, and
`**.md`, so the bot's tag-bump commits don't trigger another build (no loop).

Files involved:
- `.github/workflows/deploy.yml` — CI build/push only (no deploy job)
- `clusters/demo/namespace.yaml` — the `miriam-nkp-demo` namespace
- `clusters/demo/scuba-helmrelease.yaml` — deploys the Helm chart, carries the image-policy markers
- `clusters/demo/image-automation.yaml` — ImageRepository + ImagePolicy + ImageUpdateAutomation
- `scripts/reseal-secrets.sh` — re-seals the MySQL + app-db secrets for this cluster/namespace

---

## One-time cluster prep

Do this once on the demo cluster. After this the cluster stays "prepared" — you
only spin the app up/down per demo (see last section).

### 1. Point kubectl at the demo cluster

```bash
export KUBECONFIG=~/.kube/<demo-cluster>.conf
kubectl get nodes        # sanity check
```

### 2. Install the Sealed Secrets controller

The chart ships `SealedSecret` objects, so the controller must exist before the
app is deployed.

```bash
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace sealed-secrets --create-namespace
```

### 3. Re-seal the secrets for this cluster + namespace

The committed blobs were sealed for the *old* cluster and the
`miriam-scuba-sealed` namespace — they will not unseal here. Regenerate them:

```bash
export KUBECONFIG=~/.kube/<demo-cluster>.conf   # still pointing at demo cluster
./scripts/reseal-secrets.sh
git add deploy/charts/scuba-divelog/templates/mysql-secret.yaml \
        deploy/charts/scuba-divelog/templates/backend-db-secret.yaml
git commit -m "Re-seal scuba secrets for miriam-nkp-demo on the demo cluster"
git push origin main
```

(The script generates random DB passwords by default; pass `MYSQL_PASSWORD=...`
etc. if you want fixed ones.)

### 4. Bootstrap Flux (with image automation + write access)

The image-automation controller must be able to **push** tag-bump commits back to
`main`, so bootstrap with a read-write key (or a PAT with `repo` scope).

```bash
export GITHUB_TOKEN=<personal-access-token-with-repo-scope>

flux bootstrap github \
  --owner=miriamcsn \
  --repository=nkp-scuba-divelog \
  --branch=main \
  --path=clusters/demo \
  --components-extra=image-reflector-controller,image-automation-controller \
  --read-write-key
```

`--path=clusters/demo` tells Flux to reconcile everything under that folder, which
pulls in the namespace, the HelmRelease, and the image-automation objects.

### 5. (Only if your GHCR packages are private) add registry auth

If `ghcr.io/miriamcsn/scuba-divelog-*` are private, Flux needs pull creds to scan
them. Create the secret and uncomment the `secretRef` blocks in
`clusters/demo/image-automation.yaml`:

```bash
kubectl -n flux-system create secret docker-registry ghcr-auth \
  --docker-server=ghcr.io \
  --docker-username=miriamcsn \
  --docker-password=<PAT-with-read:packages>
```

### 6. Watch it converge

```bash
flux get kustomizations
flux get helmreleases -n miriam-nkp-demo
flux get images all -A
kubectl -n miriam-nkp-demo get pods,svc,ingress
```

---

## Verifying the automation end-to-end

```bash
# Push any change to backend/ or frontend/ on main -> CI builds a new image.
# Then watch Flux pick it up:
flux get image repository scuba-backend -n flux-system     # last scan time
flux get image policy scuba-backend -n flux-system         # latest selected tag
git log --author=fluxcdbot --oneline -5                     # the auto tag-bump commits
kubectl -n miriam-nkp-demo get deploy scuba-backend -o jsonpath='{.spec.template.spec.containers[0].image}'
```

---

## Per-demo: spin up / tear down (cluster stays prepared)

Because the desired state lives in Git, the app is "always declared." You just
suspend/resume the HelmRelease around a demo.

**Spin up (start of demo):**
```bash
flux resume helmrelease scuba -n miriam-nkp-demo
```

**Tear down (after demo) — keeps Flux, Sealed Secrets, and GHCR auth in place:**
```bash
flux suspend helmrelease scuba -n miriam-nkp-demo
helm uninstall scuba -n miriam-nkp-demo
# StatefulSet PVCs are not removed by helm uninstall; delete for a clean DB next time:
kubectl -n miriam-nkp-demo delete pvc -l app.kubernetes.io/name=mysql
```

Next demo: `flux resume helmrelease scuba -n miriam-nkp-demo` and Flux redeploys a
fresh copy at the latest image tag.

---

## Notes / gotchas

- **API versions** in `image-automation.yaml` target Flux 2.x. If `flux check`
  shows a different served version for `ImageUpdateAutomation`, switch it between
  `v1beta1` and `v1beta2` to match.
- **Tag format coupling**: the CI tag `main-<unix-ts>-<sha>` and the ImagePolicy
  regex `^main-(?P<ts>[0-9]+)-[a-f0-9]+$` must stay in sync. Change one, change both.
- **`:latest`** is still pushed for humans, but Flux ignores it (doesn't match the
  policy regex), so it never drives a deploy.
- **Namespace is now portable**: the secret templates use `{{ .Release.Namespace }}`,
  so the only thing tying the app to `miriam-nkp-demo` is the HelmRelease. To use a
  different namespace, change it there and re-run `reseal-secrets.sh` with
  `NAMESPACE=<new-ns>`.
