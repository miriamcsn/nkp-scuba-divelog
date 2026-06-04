#!/usr/bin/env bash
# Creates the entire Helm chart for the scuba dive log under deploy/charts/scuba-divelog/
# Run this from the repo root (the directory that contains backend/, frontend/, deploy/, docs/).
set -euo pipefail

CHART_DIR="deploy/charts/scuba-divelog"
mkdir -p "$CHART_DIR/templates"

# ---------- Chart.yaml ----------
cat > "$CHART_DIR/Chart.yaml" <<'EOF'
apiVersion: v2
name: scuba-divelog
description: A scuba diving log application demo for NKP
type: application
version: 0.1.0
appVersion: "0.1.0"
EOF

# ---------- values.yaml ----------
cat > "$CHART_DIR/values.yaml" <<'EOF'
# Image registry + pull policy shared by both components
image:
  registry: ghcr.io/miriamcsn
  pullPolicy: IfNotPresent

# Backend: FastAPI + SQLite, single replica because SQLite is single-writer
backend:
  image:
    repository: scuba-divelog-backend
    tag: "0.1.0"
  replicaCount: 1
  port: 8000
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
  persistence:
    enabled: true
    size: 1Gi
    storageClassName: nutanix-volume
    mountPath: /data

# Frontend: nginx serving static HTML + proxying /api to the backend
frontend:
  image:
    repository: scuba-divelog-frontend
    tag: "0.1.0"
  replicaCount: 2
  port: 80
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
    limits:
      cpu: 200m
      memory: 128Mi

# Ingress (Traefik via NKP Kommander)
ingress:
  enabled: true
  className: kommander-traefik
  host: ""            # leave empty to match any host (we'll hit the LoadBalancer IP directly)
  path: /
  pathType: Prefix
EOF

# ---------- .helmignore ----------
cat > "$CHART_DIR/.helmignore" <<'EOF'
.DS_Store
.git/
.gitignore
*.tmproj
*.bak
*.swp
*~
EOF

# ---------- templates/_helpers.tpl ----------
cat > "$CHART_DIR/templates/_helpers.tpl" <<'EOF'
{{/* Standard labels applied to every object */}}
{{- define "scuba-divelog.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/* Selector labels — used by Services to find their Pods and Deployments to match their templates */}}
{{- define "scuba-divelog.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
EOF

# ---------- templates/backend-pvc.yaml ----------
cat > "$CHART_DIR/templates/backend-pvc.yaml" <<'EOF'
{{- if .Values.backend.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Release.Name }}-backend-data
  labels:
    {{- include "scuba-divelog.labels" . | nindent 4 }}
    app.kubernetes.io/component: backend
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ .Values.backend.persistence.storageClassName }}
  resources:
    requests:
      storage: {{ .Values.backend.persistence.size }}
{{- end }}
EOF

# ---------- templates/backend-deployment.yaml ----------
cat > "$CHART_DIR/templates/backend-deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-backend
  labels:
    {{- include "scuba-divelog.labels" . | nindent 4 }}
    app.kubernetes.io/component: backend
spec:
  replicas: {{ .Values.backend.replicaCount }}
  # Recreate: stop the old pod before starting the new one — avoids two pods
  # contending for the same SQLite file on the ReadWriteOnce PVC.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "scuba-divelog.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: backend
  template:
    metadata:
      labels:
        {{- include "scuba-divelog.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: backend
    spec:
      containers:
        - name: backend
          image: "{{ .Values.image.registry }}/{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.backend.port }}
              protocol: TCP
          env:
            - name: DATABASE_URL
              value: "sqlite:///{{ .Values.backend.persistence.mountPath }}/divelog.db"
          volumeMounts:
            - name: data
              mountPath: {{ .Values.backend.persistence.mountPath }}
          resources:
            {{- toYaml .Values.backend.resources | nindent 12 }}
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
      volumes:
        - name: data
          {{- if .Values.backend.persistence.enabled }}
          persistentVolumeClaim:
            claimName: {{ .Release.Name }}-backend-data
          {{- else }}
          emptyDir: {}
          {{- end }}
EOF

# ---------- templates/backend-service.yaml ----------
cat > "$CHART_DIR/templates/backend-service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-backend
  labels:
    {{- include "scuba-divelog.labels" . | nindent 4 }}
    app.kubernetes.io/component: backend
spec:
  type: ClusterIP
  ports:
    - name: http
      port: {{ .Values.backend.port }}
      targetPort: http
      protocol: TCP
  selector:
    {{- include "scuba-divelog.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: backend
EOF

# ---------- templates/frontend-configmap.yaml ----------
cat > "$CHART_DIR/templates/frontend-configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-frontend-nginx
  labels:
    {{- include "scuba-divelog.labels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
data:
  default.conf: |
    server {
        listen 80;
        server_name _;
        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ /index.html;
        }

        # Proxy /api/* to the backend Service. Cluster DNS resolves
        # "<release>-backend" to the backend Service's ClusterIP.
        location /api/ {
            proxy_pass http://{{ .Release.Name }}-backend:{{ .Values.backend.port }}/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
EOF

# ---------- templates/frontend-deployment.yaml ----------
cat > "$CHART_DIR/templates/frontend-deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-frontend
  labels:
    {{- include "scuba-divelog.labels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
spec:
  replicas: {{ .Values.frontend.replicaCount }}
  selector:
    matchLabels:
      {{- include "scuba-divelog.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: frontend
  template:
    metadata:
      labels:
        {{- include "scuba-divelog.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: frontend
    spec:
      containers:
        - name: frontend
          image: "{{ .Values.image.registry }}/{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.frontend.port }}
              protocol: TCP
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
          resources:
            {{- toYaml .Values.frontend.resources | nindent 12 }}
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 20
      volumes:
        - name: nginx-conf
          configMap:
            name: {{ .Release.Name }}-frontend-nginx
EOF

# ---------- templates/frontend-service.yaml ----------
cat > "$CHART_DIR/templates/frontend-service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-frontend
  labels:
    {{- include "scuba-divelog.labels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
spec:
  type: ClusterIP
  ports:
    - name: http
      port: {{ .Values.frontend.port }}
      targetPort: http
      protocol: TCP
  selector:
    {{- include "scuba-divelog.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
EOF

# ---------- templates/ingress.yaml ----------
cat > "$CHART_DIR/templates/ingress.yaml" <<'EOF'
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  labels:
    {{- include "scuba-divelog.labels" . | nindent 4 }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    {{- if .Values.ingress.host }}
    - host: {{ .Values.ingress.host }}
      http:
    {{- else }}
    - http:
    {{- end }}
        paths:
          - path: {{ .Values.ingress.path }}
            pathType: {{ .Values.ingress.pathType }}
            backend:
              service:
                name: {{ .Release.Name }}-frontend
                port:
                  number: {{ .Values.frontend.port }}
{{- end }}
EOF

# ---------- templates/NOTES.txt ----------
cat > "$CHART_DIR/templates/NOTES.txt" <<'EOF'
🤿 Scuba Dive Log installed!

Release:   {{ .Release.Name }}
Namespace: {{ .Release.Namespace }}

Wait for pods:
  kubectl -n {{ .Release.Namespace }} get pods -w

Find the cluster's Traefik LoadBalancer IP:
  kubectl get svc -n kommander kommander-traefik

Then open in your browser:
  http://<LOADBALANCER-IP>/

You should see the scuba-themed page. Add a diver, a site, log a dive.

To uninstall:
  helm uninstall {{ .Release.Name }} -n {{ .Release.Namespace }}
EOF

echo ""
echo "Helm chart created at $CHART_DIR"
echo ""
echo "Next steps:"
echo "  helm lint $CHART_DIR"
echo "  helm template scuba $CHART_DIR --namespace scuba | less     # dry-render to inspect"
echo "  helm install scuba $CHART_DIR --namespace scuba --create-namespace"
echo ""