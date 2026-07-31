# scuba-divelog (no sealed-secrets)

Standalone variant of `deploy/charts/scuba-divelog` with the sealed-secrets
dependency removed. MySQL credentials (`rootpw` / `divelog`/`divelog`/`divelog`,
same as `compose.yml`) are hardcoded in plain `Secret` manifests
(`templates/mysql-secret.yaml`, `templates/backend-db-secret.yaml`) instead of
`SealedSecret` objects. No sealed-secrets controller, no Flux GitRepository/
HelmRelease wiring required — just Helm.

The ingress has no `host` set, so it's reachable directly through the
Traefik LoadBalancer IP instead of a DNS name.

## Install

```
helm install scuba . -n <namespace> --create-namespace
```

## Uninstall

```
helm uninstall scuba -n <namespace>
```

Demo credentials only — do not reuse in a real deployment.
