# Runbook: Deploy Scuba App to a New NKP Cluster via GitOps

## What this does

Push to `main` → GitHub Actions builds and pushes an image to GHCR → Flux (running in `kommander-flux`) detects the new tag via `ImageRepository`/`ImagePolicy`, commits the tag bump back to Git via `ImageUpdateAutomation`, then reconciles the `HelmRelease` with the new image. Database secrets are stored in Git as `SealedSecret` objects — encrypted with the cluster's public key, decryptable only by that cluster's Sealed Secrets controller.

> **NKP rule:** Never run `flux bootstrap` or `flux install`. NKP ships with Flux in `kommander-flux` — wire into it with `kubectl apply`.

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| `kubectl` | Talk to the cluster |
| `helm` | Install Sealed Secrets controller |
| `kubeseal` | Encrypt secrets for a specific cluster |
| `git` | Push config to the repo |

**Sealed Secrets must be installed on the target cluster.** NKP does not ship it by default:

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update sealed-secrets
KUBECONFIG=$KUBECONFIG_PATH helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace sealed-secrets \
  --create-namespace \
  --wait
```

**GitHub PAT required** — needs two permissions:
- `read:packages` (so Flux can poll GHCR for new image tags)
- `contents: write` (so Flux can push tag-bump commits to the repo)

The existing PAT (`github-auth` secret) can be reused if you still have it.

---

## Variables — set these first

Every command below uses these variables. Set them once in your terminal before starting.

```bash
# Name for this cluster (used in folder names, log messages, etc.)
CLUSTER_NAME=wl-c

# Path to the kubeconfig for the target cluster
KUBECONFIG_PATH=~/.kube/nkp-c.conf

# Namespace where the app will run (keep this consistent — sealed secrets are tied to it)
APP_NAMESPACE=miriam-scuba-sealed

# Your GitHub username and PAT
GH_USER=miriamcsn
GH_PAT=ghp_xxxxxxxxxxxxxxxxxxxx

# Local path to this repo
REPO_ROOT=/Users/miriamgorino/nkp-scuba-divelog
```

---

## Step 1 — Create the cluster folder in Git

Copy the `wl-b` folder and substitute the cluster name.

```bash
cd $REPO_ROOT

# Create new cluster folder
cp -r clusters/wl-b clusters/$CLUSTER_NAME

# Update the cluster tag in the ImageUpdateAutomation commit message
# (helps you know which cluster triggered a tag-bump commit)
sed -i '' "s/\[wl-b\]/[$CLUSTER_NAME]/" clusters/$CLUSTER_NAME/image-automation.yaml

# Update the image automation path so Flux only rewrites tags in this cluster's folder
sed -i '' "s|path: ./clusters/wl-b|path: ./clusters/$CLUSTER_NAME|" clusters/$CLUSTER_NAME/image-automation.yaml
```

**Check the result:**
```bash
grep -n "wl-b" clusters/$CLUSTER_NAME/image-automation.yaml
# Should return nothing — all references replaced
```

The folder contains three files — here's what each one does:

| File | What Flux does with it |
|------|----------------------|
| `namespace.yaml` | Creates the `miriam-scuba-sealed` namespace on the cluster |
| `scuba-helmrelease.yaml` | Tells Flux to deploy the Helm chart and keep image tags up to date |
| `image-automation.yaml` | Watches GHCR for new tags, commits tag bumps back to Git |

---

## Step 2 — Re-seal the database secrets for the new cluster

**Why:** Sealed Secrets uses public-key encryption. Each cluster has its own private key — a secret encrypted for cluster A cannot be decrypted by cluster B. You must re-seal for every new cluster.

### 2a. Fetch the new cluster's public certificate

```bash
CERT_FILE=/tmp/$CLUSTER_NAME-sealed-cert.pem

KUBECONFIG=$KUBECONFIG_PATH kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > $CERT_FILE 2>/dev/null

# Verify it looks like a real cert
head -2 $CERT_FILE
# Should output: -----BEGIN CERTIFICATE-----
```

> If `--fetch-cert` fails, fall back to:
> ```bash
> KUBECONFIG=$KUBECONFIG_PATH kubectl get secret \
>   -n sealed-secrets \
>   -l sealedsecrets.bitnami.com/sealed-secrets-key \
>   -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > $CERT_FILE
> ```

### 2b. Generate and seal new database credentials

This script generates random passwords, seals them with the cluster cert, and writes the SealedSecret YAML files into the chart templates.

```bash
NAMESPACE=$APP_NAMESPACE
MYSQL_DATABASE=scubadb
MYSQL_USER=scuba
MYSQL_PASSWORD=$(openssl rand -hex 16)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)
DATABASE_URL="mysql+pymysql://${MYSQL_USER}:${MYSQL_PASSWORD}@scuba-mysql:3306/${MYSQL_DATABASE}"

seal_raw() {
  printf '%s' "$2" | kubeseal --raw --cert "$CERT_FILE" \
    --scope namespace-wide \
    --namespace "$NAMESPACE" \
    --name "$1"
}

DB_DATABASE=$(seal_raw scuba-mysql "$MYSQL_DATABASE")
DB_USER=$(seal_raw scuba-mysql "$MYSQL_USER")
DB_PASSWORD=$(seal_raw scuba-mysql "$MYSQL_PASSWORD")
DB_ROOT=$(seal_raw scuba-mysql "$MYSQL_ROOT_PASSWORD")
APP_DATABASE_URL=$(seal_raw scuba-app-db "$DATABASE_URL")

echo "Sealed. mysql-user prefix: ${DB_USER:0:20}..."
```

### 2c. Write the sealed values to the chart templates

```bash
CHART_TEMPLATES=$REPO_ROOT/deploy/charts/scuba-divelog/templates

cat > "${CHART_TEMPLATES}/mysql-secret.yaml" <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
  labels:
    app.kubernetes.io/instance: scuba
  name: scuba-mysql
  namespace: {{ .Release.Namespace }}
spec:
  encryptedData:
    mysql-database: ${DB_DATABASE}
    mysql-password: ${DB_PASSWORD}
    mysql-root-password: ${DB_ROOT}
    mysql-user: ${DB_USER}
  template:
    metadata:
      annotations:
        sealedsecrets.bitnami.com/namespace-wide: "true"
      labels:
        app.kubernetes.io/instance: scuba
      name: scuba-mysql
      namespace: {{ .Release.Namespace }}
EOF

cat > "${CHART_TEMPLATES}/backend-db-secret.yaml" <<'HELM'
{{- if .Values.mysql.enabled }}
HELM
cat >> "${CHART_TEMPLATES}/backend-db-secret.yaml" <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
  labels:
    app.kubernetes.io/instance: scuba
  name: scuba-app-db
  namespace: {{ .Release.Namespace }}
spec:
  encryptedData:
    DATABASE_URL: ${APP_DATABASE_URL}
  template:
    metadata:
      annotations:
        sealedsecrets.bitnami.com/namespace-wide: "true"
      labels:
        app.kubernetes.io/instance: scuba
      name: scuba-app-db
      namespace: {{ .Release.Namespace }}
EOF
echo "{{- end }}" >> "${CHART_TEMPLATES}/backend-db-secret.yaml"

echo "Done writing sealed secrets."
```

### 2d. Bump the chart version

This forces the Flux source controller to re-package the chart with the new sealed values.  
(Without this, the source controller may serve a cached tarball with the old secrets.)

```bash
# Read the version from main (not local — Flux may have pushed commits ahead of you)
CHART_FILE=$REPO_ROOT/deploy/charts/scuba-divelog/Chart.yaml
CURRENT=$(git show origin/main:deploy/charts/scuba-divelog/Chart.yaml | grep '^version:' | awk '{print $2}')
NEW=$(echo $CURRENT | awk -F. '{print $1"."$2"."$3+1}')
sed -i '' "s/^version: .*/version: $NEW/" $CHART_FILE
echo "Chart bumped: $CURRENT → $NEW"
```

---

## Step 3 — Commit everything to main

Flux watches the `main` branch. Changes only take effect once they're on `main`.

```bash
cd $REPO_ROOT
git checkout main
git pull origin main

git add clusters/$CLUSTER_NAME/ \
        deploy/charts/scuba-divelog/templates/mysql-secret.yaml \
        deploy/charts/scuba-divelog/templates/backend-db-secret.yaml \
        deploy/charts/scuba-divelog/Chart.yaml

git commit -m "feat: add GitOps pipeline for cluster $CLUSTER_NAME"
git push origin main
```

---

## Step 4 — Bootstrap Flux on the new cluster (run once per cluster)

These three `kubectl` commands wire the new cluster into the pipeline.  
They are **not** stored in Git — they must be applied manually once.

### 4a. Create the GitHub PAT secret

Flux needs this to pull from GitHub and push tag-bump commits.

```bash
KUBECONFIG=$KUBECONFIG_PATH kubectl create secret generic github-auth \
  -n kommander-flux \
  --from-literal=username=$GH_USER \
  --from-literal=password=$GH_PAT
```

### 4b. Apply the GitRepository

Tells Flux where the Git repo is and which branch to watch.

```bash
KUBECONFIG=$KUBECONFIG_PATH kubectl apply -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: nkp-scuba-divelog
  namespace: kommander-flux
spec:
  interval: 1m
  url: https://github.com/$GH_USER/nkp-scuba-divelog
  ref:
    branch: main
  secretRef:
    name: github-auth
EOF
```

### 4c. Apply the Kustomization

Tells Flux to apply everything inside `clusters/$CLUSTER_NAME/` to this cluster.

```bash
KUBECONFIG=$KUBECONFIG_PATH kubectl apply -f - <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: scuba-$CLUSTER_NAME
  namespace: kommander-flux
spec:
  interval: 5m
  path: ./clusters/$CLUSTER_NAME
  prune: true
  sourceRef:
    kind: GitRepository
    name: nkp-scuba-divelog
  timeout: 5m
EOF
```

---

## Step 5 — Verify

Run these checks in order — each depends on the previous succeeding.

```bash
# 1. GitRepository is synced to latest main commit
KUBECONFIG=$KUBECONFIG_PATH kubectl get gitrepository nkp-scuba-divelog -n kommander-flux
# Expect: READY=True, STATUS shows latest commit SHA

# 2. Kustomization applied (namespace + helmrelease + image objects created)
KUBECONFIG=$KUBECONFIG_PATH kubectl get kustomization scuba-$CLUSTER_NAME -n kommander-flux
# Expect: READY=True

# 3. Namespace created
KUBECONFIG=$KUBECONFIG_PATH kubectl get namespace $APP_NAMESPACE
# Expect: Active

# 4. Sealed Secrets decrypted (this confirms the cert was correct)
KUBECONFIG=$KUBECONFIG_PATH kubectl get sealedsecrets -n $APP_NAMESPACE
# Expect: SYNCED=True for both scuba-mysql and scuba-app-db
# If you see "no key could decrypt secret" → the sealed cert was wrong, redo Step 2

# 5. HelmRelease succeeded
KUBECONFIG=$KUBECONFIG_PATH kubectl get helmrelease scuba -n $APP_NAMESPACE
# Expect: READY=True, "Helm upgrade succeeded"

# 6. All pods running
KUBECONFIG=$KUBECONFIG_PATH kubectl get pods -n $APP_NAMESPACE
# Expect: scuba-mysql-0, scuba-backend-*, scuba-frontend-* all 1/1 Running
```

**Quick access in browser:**
```bash
KUBECONFIG=$KUBECONFIG_PATH kubectl port-forward svc/scuba-frontend 8080:80 -n $APP_NAMESPACE
# Open http://localhost:8080 — Ctrl+C to stop
```

---

## Troubleshooting

### `no key could decrypt secret`

The SealedSecret was sealed with a different cluster's key.  
→ Redo Step 2 from scratch with the correct `$CERT_FILE`, then re-commit.

### HelmRelease stuck in `RetriesExceeded`

The HelmRelease has tried too many times and given up. Reset it:
```bash
KUBECONFIG=$KUBECONFIG_PATH kubectl patch helmrelease scuba -n $APP_NAMESPACE \
  --type=merge -p '{"spec":{"suspend":true}}'
KUBECONFIG=$KUBECONFIG_PATH kubectl patch helmrelease scuba -n $APP_NAMESPACE \
  --type=merge -p '{"spec":{"suspend":false}}'
```

### HelmChart not picking up new sealed secrets (same digest after commit)

The source controller cached the old chart tarball. Fix: bump the chart version (Step 2d) and push again.

### GitRepository auth fails

Check the `github-auth` secret was created with the right PAT:
```bash
KUBECONFIG=$KUBECONFIG_PATH kubectl get secret github-auth -n kommander-flux -o jsonpath='{.data.password}' | base64 -d
```

### Force immediate reconciliation (don't want to wait 5m)

```bash
KUBECONFIG=$KUBECONFIG_PATH kubectl annotate gitrepository nkp-scuba-divelog -n kommander-flux \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite

KUBECONFIG=$KUBECONFIG_PATH kubectl annotate kustomization scuba-$CLUSTER_NAME -n kommander-flux \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

---

## Architecture summary

```
GitHub repo (main)
  clusters/<name>/
    namespace.yaml
    scuba-helmrelease.yaml
    image-automation.yaml
  deploy/charts/scuba-divelog/templates/
    mysql-secret.yaml        # SealedSecret — cluster-specific, must re-seal per cluster
    backend-db-secret.yaml   # SealedSecret — cluster-specific, must re-seal per cluster

kommander-flux (per cluster)
  GitRepository        → polls GitHub every 1m
  Kustomization        → applies clusters/<name>/ every 5m
  ImageRepository      → polls GHCR every 5m
  ImagePolicy          → selects latest tag by unix timestamp
  ImageUpdateAutomation → writes tag-bump commits to main
```
