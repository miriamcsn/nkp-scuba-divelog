#!/usr/bin/env bash
#
# reseal-secrets.sh
# -----------------
# SealedSecrets are encrypted against ONE cluster's controller key and bound to a
# namespace. The blobs committed in the chart were sealed for the old cluster +
# namespace "miriam-scuba-sealed", so they will NOT unseal on a new cluster or in
# a new namespace. Run this once per cluster to regenerate them for the demo
# namespace, then commit the result.
#
# It rewrites the two chart templates in place, keeping the Helm templating
# ({{ .Release.Namespace }}) and replacing only the encrypted values.
#
# Requirements: kubeseal, kubectl, openssl, KUBECONFIG pointing at the demo cluster
# with the sealed-secrets controller already installed.
#
# Usage:
#   export KUBECONFIG=~/.kube/<demo-cluster>.conf
#   ./scripts/reseal-secrets.sh
#
# Override any value via env var, e.g.:
#   MYSQL_PASSWORD=hunter2 ./scripts/reseal-secrets.sh
#
set -euo pipefail

# ---- config -----------------------------------------------------------------
NAMESPACE="${NAMESPACE:-miriam-nkp-demo}"
SCOPE="namespace-wide"

# sealed-secrets controller location (override if you installed it elsewhere)
CONTROLLER_NS="${CONTROLLER_NS:-sealed-secrets}"
CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets}"

# Secret values (sensible demo defaults; passwords auto-generated if unset)
MYSQL_DATABASE="${MYSQL_DATABASE:-scubadb}"
MYSQL_USER="${MYSQL_USER:-scuba}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(openssl rand -hex 16)}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(openssl rand -hex 16)}"

# Backend connection string. Service name is "<release>-mysql" = "scuba-mysql".
DATABASE_URL="${DATABASE_URL:-mysql+pymysql://${MYSQL_USER}:${MYSQL_PASSWORD}@scuba-mysql:3306/${MYSQL_DATABASE}}"

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)/deploy/charts/scuba-divelog/templates"
MYSQL_FILE="${CHART_DIR}/mysql-secret.yaml"
APPDB_FILE="${CHART_DIR}/backend-db-secret.yaml"

# ---- helpers ----------------------------------------------------------------
seal_raw() {   # seal_raw <secret-name> <plaintext>
  local name="$1" value="$2"
  printf '%s' "$value" | kubeseal --raw \
    --scope "$SCOPE" \
    --namespace "$NAMESPACE" \
    --name "$name" \
    --controller-namespace "$CONTROLLER_NS" \
    --controller-name "$CONTROLLER_NAME"
}

echo ">> Sealing for namespace '${NAMESPACE}' (scope: ${SCOPE})"
echo ">> Using sealed-secrets controller ${CONTROLLER_NS}/${CONTROLLER_NAME}"

# ---- seal each value --------------------------------------------------------
DB_DATABASE=$(seal_raw scuba-mysql "$MYSQL_DATABASE")
DB_USER=$(seal_raw scuba-mysql "$MYSQL_USER")
DB_PASSWORD=$(seal_raw scuba-mysql "$MYSQL_PASSWORD")
DB_ROOT=$(seal_raw scuba-mysql "$MYSQL_ROOT_PASSWORD")
APP_DATABASE_URL=$(seal_raw scuba-app-db "$DATABASE_URL")

# ---- write mysql-secret.yaml ------------------------------------------------
cat > "$MYSQL_FILE" <<EOF
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

# ---- write backend-db-secret.yaml -------------------------------------------
cat > "$APPDB_FILE" <<EOF
{{- if .Values.mysql.enabled }}
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
{{- end }}
EOF

echo ">> Rewrote:"
echo "     $MYSQL_FILE"
echo "     $APPDB_FILE"
echo
echo ">> Plaintext used (store these somewhere safe if you need them):"
echo "     mysql database : ${MYSQL_DATABASE}"
echo "     mysql user     : ${MYSQL_USER}"
echo "     mysql password : ${MYSQL_PASSWORD}"
echo "     mysql root pw  : ${MYSQL_ROOT_PASSWORD}"
echo
echo ">> Next: git add the two files, commit, and push. Flux will apply them."
