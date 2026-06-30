# Claude Working Rules for this Project

## Mandatory protocol for every action

Before executing **any** command, code change, or kubectl/helm/bash operation, I must state:

1. **What**: what the command does, in plain language
2. **Scope**: what is affected — a specific namespace, the whole cluster, both clusters, a file, etc.
3. **Consequences**: what changes as a result, including any side effects or risks

Every action requires **explicit approval** before I execute it.

This applies to:
- `kubectl` commands (get, apply, patch, delete, exec, etc.)
- `helm` commands
- Any shell script or bash command
- File edits or writes
- Any change that touches cluster state

## No exceptions

No command is "safe enough to skip the protocol." Read-only commands (`kubectl get`, `kubectl describe`) still get described before running — even those can expose sensitive data or have unexpected scope.

## Context

This project manages NKP (Nutanix Kubernetes Platform) clusters. Changes can affect production workloads and live demos. The cost of a wrong action is high.
