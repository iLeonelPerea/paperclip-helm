# Paperclip Helm Chart — Test Plan

**Chart:** paperclip  
**Version:** See Chart.yaml  
**Target environments:** Docker Desktop K8s, OVH Kubernetes  
**Last updated:** 2026-04-14  

---

## Overview

This test plan validates the Paperclip Helm chart across all supported configurations and deployment scenarios. Tests are organized in phases:

- **Phase 0:** Pre-validation (Helm lint, template rendering, no cluster required)
- **Phase 1:** Deployment to Docker Desktop
- **Phase 2:** Feature verification (ingress, networkPolicy, PDB, external DB, Vault)
- **Phase 3:** Cleanup

---

## Phase 0 — Pre-validation (No cluster required)

### 0.1 — Helm Lint

Validate chart structure and dependencies.

```bash
helm lint .
```

**Expected output:**
```
1 chart(s) linted, 0 chart(s) failed
```

- [ ] Lint passes with 0 failures

---

### 0.2 — Template Render (Defaults)

Render templates with default values from `values.yaml`.

```bash
helm template paperclip . > /tmp/rendered-defaults.yaml
```

**Expected behavior:**
- No errors during rendering
- Output is valid YAML
- `rendered-defaults.yaml` contains all manifests

**Verification:**
```bash
cat /tmp/rendered-defaults.yaml | grep '^kind:' | sort | uniq -c
```

Expected kinds: `Deployment`, `Service`, `StatefulSet` (postgres), `ConfigMap`, `Secret`, `PersistentVolumeClaim`

- [ ] Template renders successfully with defaults
- [ ] All expected resource kinds present

---

### 0.3 — Template Render (All Features Enabled)

Render with all optional features enabled: ingress, networkPolicy, PDB.

```bash
helm template paperclip . \
  --set ingress.enabled=true \
  --set networkPolicy.enabled=true \
  --set podDisruptionBudget.enabled=true \
  > /tmp/rendered-all-features.yaml
```

**Expected behavior:**
- No errors during rendering
- Additional resources created:
  - `Ingress` resource (name: `paperclip`)
  - `NetworkPolicy` resources (2x: default-deny and allow-from-ingress)
  - `PodDisruptionBudget` resource

**Verification:**
```bash
grep -E '^kind: (Ingress|NetworkPolicy|PodDisruptionBudget)' /tmp/rendered-all-features.yaml
```

Expected output:
```
kind: Ingress
kind: NetworkPolicy
kind: NetworkPolicy
kind: PodDisruptionBudget
```

- [ ] Template renders with all features enabled
- [ ] Ingress resource created
- [ ] 2x NetworkPolicy resources created
- [ ] PodDisruptionBudget resource created

---

### 0.4 — Template Render (External Database)

Render with PostgreSQL disabled and external DB configured.

```bash
helm template paperclip . \
  --set postgresql.enabled=false \
  --set externalDatabase.url="postgresql://user:pass@db.example.com:5432/paperclip" \
  > /tmp/rendered-external-db.yaml
```

**Expected behavior:**
- No errors during rendering
- No PostgreSQL StatefulSet or related resources
- Paperclip deployment uses external DB connection string

**Verification:**
```bash
grep -E '^kind: StatefulSet' /tmp/rendered-external-db.yaml
```

Expected: No StatefulSet (postgres is disabled)

```bash
grep -A 5 'DATABASE_URL' /tmp/rendered-external-db.yaml | head -1
```

Expected: Reference to `externalDatabase.url` or similar

- [ ] Template renders with external DB enabled
- [ ] No PostgreSQL StatefulSet in output
- [ ] Deployment configured to use external DB

---

### 0.5 — Template Render (Vault Integration)

Render with Vault enabled (ExternalSecret and ClusterSecretStore).

```bash
helm template paperclip . \
  --set vault.enabled=true \
  --set vault.namespace=vault \
  > /tmp/rendered-vault.yaml
```

**Expected behavior:**
- No errors during rendering
- `ExternalSecret` resource created
- `ClusterSecretStore` resource created

**Verification:**
```bash
grep -E '^kind: (ExternalSecret|ClusterSecretStore)' /tmp/rendered-vault.yaml
```

Expected:
```
kind: ClusterSecretStore
kind: ExternalSecret
```

- [ ] Template renders with Vault enabled
- [ ] ClusterSecretStore resource created
- [ ] ExternalSecret resource created

---

### 0.6 — Security Context & Init Container Validation

Verify rendered defaults include required security controls.

```bash
helm template paperclip . | grep -A 10 'securityContext:' | head -20
helm template paperclip . | grep -A 5 'initContainers:' | head -10
```

**Expected:**
- `seccompProfile: type: RuntimeDefault` present in pod spec
- `securityContext` with appropriate capabilities
- `initContainers` for database initialization (if PostgreSQL enabled)

- [ ] Security context properly configured
- [ ] seccompProfile set to RuntimeDefault
- [ ] Init containers present (if applicable)

---

## Phase 1 — Deployment to Docker Desktop K8s

### Prerequisites

- Docker Desktop running with Kubernetes enabled
- `kubectl` configured for `docker-desktop` context
- `helm` CLI available

**Verify context:**
```bash
kubectl config current-context
```

Expected: `docker-desktop`

- [ ] Docker Desktop context active

---

### 1.1 — Create Namespace

```bash
kubectl create namespace paperclip
```

Expected: Namespace created successfully

- [ ] Namespace created

---

### 1.2 — Install Chart (Minimal Configuration)

Install with required secret and PostgreSQL password.

```bash
helm install paperclip . \
  --namespace paperclip \
  --set auth.betterAuthSecret="testsecretminimum32charslong1234" \
  --set postgresql.auth.password="testpass123"
```

**Expected behavior:**
- Installation succeeds
- Resources begin starting

**Verification:**
```bash
kubectl get all -n paperclip
```

Expected: Deployment, Service, StatefulSet (postgres), and associated pods

- [ ] Helm install succeeds
- [ ] All resources created in namespace

---

### 1.3 — Wait for PostgreSQL Readiness

Monitor PostgreSQL StatefulSet startup (~1-2 minutes).

```bash
kubectl get pods -n paperclip -w
```

Watch for:
- `paperclip-postgresql-0` → Running → Ready (2/2)
- PostgreSQL readinessProbe: `pg_isready -U paperclip -d paperclip`

Exit watch once postgres is Ready (Ctrl+C).

- [ ] PostgreSQL pod running
- [ ] PostgreSQL pod marked Ready

---

### 1.4 — Verify PostgreSQL Init Container

Check that database initialization completed successfully.

```bash
kubectl logs -n paperclip paperclip-postgresql-0 -c paperclip-init-db
```

Expected output:
- Database creation logs
- Schema initialization (if applicable)
- No errors

- [ ] Init container logs show successful initialization
- [ ] No errors in initialization logs

---

### 1.5 — Wait for Server Readiness

Monitor Paperclip deployment startup (~1-2 minutes after postgres is ready).

```bash
kubectl get pods -n paperclip -w
```

Watch for:
- `paperclip-*` deployment pod → Running → Ready (1/1)
- Readiness probe: HTTP GET on port 3100

Exit watch once server is Ready (Ctrl+C).

- [ ] Paperclip deployment pod running
- [ ] Paperclip pod marked Ready

---

### 1.6 — Verify Service Connectivity

Test service DNS and connectivity.

```bash
kubectl run -n paperclip -it --rm --image=busybox --restart=Never -- \
  wget -q -O - http://paperclip:3100/health
```

Expected: HTTP 200 response or similar health check response

- [ ] Service DNS resolves
- [ ] Server responds to HTTP requests

---

### 1.7 — Port-Forward and UI Access

Set up port-forward and test UI.

```bash
kubectl port-forward -n paperclip svc/paperclip 3100:3100 &
PF_PID=$!
sleep 2
curl -I http://localhost:3100/
kill $PF_PID
```

Expected:
- Port-forward established
- HTTP 200 response from server

- [ ] Port-forward works
- [ ] Server responds on localhost:3100

---

## Phase 2 — Feature Verification

### 2.1 — Ingress Feature

Upgrade deployment to enable Ingress.

```bash
helm upgrade paperclip . \
  --namespace paperclip \
  --set ingress.enabled=true \
  --set ingress.host=paperclip.local
```

**Verification:**
```bash
kubectl get ingress -n paperclip
kubectl describe ingress -n paperclip paperclip
```

Expected:
- Ingress resource exists
- Backend: paperclip:3100
- Rules: Host `paperclip.local`

- [ ] Ingress resource created
- [ ] Correct backend service configured
- [ ] Hostname matches config

---

### 2.2 — NetworkPolicy Feature

Upgrade deployment to enable NetworkPolicy.

```bash
helm upgrade paperclip . \
  --namespace paperclip \
  --set networkPolicy.enabled=true
```

**Verification:**
```bash
kubectl get networkpolicy -n paperclip
kubectl describe networkpolicy -n paperclip
```

Expected:
- 2x NetworkPolicy resources
  - `paperclip-default-deny`: Deny all egress/ingress
  - `paperclip-allow-from-ingress`: Allow traffic from ingress-nginx namespace

- [ ] 2x NetworkPolicy resources created
- [ ] Default-deny policy present
- [ ] Allow-from-ingress policy present

---

### 2.3 — PodDisruptionBudget Feature

Upgrade deployment to enable PDB.

```bash
helm upgrade paperclip . \
  --namespace paperclip \
  --set podDisruptionBudget.enabled=true \
  --set podDisruptionBudget.minAvailable=1
```

**Verification:**
```bash
kubectl get pdb -n paperclip
kubectl describe pdb -n paperclip paperclip
```

Expected:
- PDB resource exists
- minAvailable: 1
- Selector matches paperclip pods

- [ ] PDB resource created
- [ ] minAvailable set correctly
- [ ] Pod selector matches deployment

---

### 2.4 — External Database Configuration

Reinstall chart with PostgreSQL disabled.

```bash
helm uninstall paperclip -n paperclip
helm install paperclip . \
  --namespace paperclip \
  --set postgresql.enabled=false \
  --set externalDatabase.url="postgresql://testuser:testpass@external-db:5432/paperclip" \
  --set auth.betterAuthSecret="testsecretminimum32charslong1234"
```

**Verification:**
```bash
kubectl get pods -n paperclip
kubectl describe deployment -n paperclip paperclip | grep -A 5 DATABASE_URL
```

Expected:
- No PostgreSQL StatefulSet pods
- Paperclip deployment runs and connects to external DB
- Deployment logs show successful connection (check after pod is ready)

- [ ] PostgreSQL disabled (no StatefulSet)
- [ ] Deployment configured with external DB URL
- [ ] Paperclip pod becomes Ready

---

### 2.5 — Vault Integration (Dry-run)

Render chart with Vault enabled to verify ExternalSecret/ClusterSecretStore creation.

```bash
helm template paperclip . \
  --set vault.enabled=true \
  --set vault.namespace=vault \
  --set vault.role=paperclip \
  | grep -E '^kind: (ExternalSecret|ClusterSecretStore)'
```

Expected output:
```
kind: ClusterSecretStore
kind: ExternalSecret
```

- [ ] ClusterSecretStore renders correctly
- [ ] ExternalSecret renders correctly

---

## Phase 3 — Cleanup

### 3.1 — Remove Helm Release

```bash
helm uninstall paperclip -n paperclip
```

Expected: Release removed successfully

- [ ] Helm release uninstalled

---

### 3.2 — Remove Namespace

```bash
kubectl delete namespace paperclip
```

Expected: Namespace and all contained resources removed

**Verification:**
```bash
kubectl get namespace paperclip
```

Expected: Error `NotFound`

- [ ] Namespace deleted

---

## Test Results Summary

| Phase | Test | Result | Notes |
|-------|------|--------|-------|
| 0 | Helm Lint | PASS/FAIL | |
| 0 | Template (defaults) | PASS/FAIL | |
| 0 | Template (all features) | PASS/FAIL | |
| 0 | Template (external DB) | PASS/FAIL | |
| 0 | Template (Vault) | PASS/FAIL | |
| 0 | Security context | PASS/FAIL | |
| 1 | Namespace creation | PASS/FAIL | |
| 1 | Chart installation | PASS/FAIL | |
| 1 | PostgreSQL readiness | PASS/FAIL | |
| 1 | Init container logs | PASS/FAIL | |
| 1 | Server readiness | PASS/FAIL | |
| 1 | Service connectivity | PASS/FAIL | |
| 1 | Port-forward test | PASS/FAIL | |
| 2 | Ingress feature | PASS/FAIL | |
| 2 | NetworkPolicy feature | PASS/FAIL | |
| 2 | PDB feature | PASS/FAIL | |
| 2 | External DB | PASS/FAIL | |
| 2 | Vault integration | PASS/FAIL | |
| 3 | Release cleanup | PASS/FAIL | |
| 3 | Namespace cleanup | PASS/FAIL | |

---

## Release Checklist

Before committing chart version bump and creating GitHub Release:

- [ ] All Phase 0 tests pass
- [ ] All Phase 1 tests pass
- [ ] All Phase 2 tests pass
- [ ] All Phase 3 tests pass
- [ ] Chart version bumped in `Chart.yaml` (semver)
- [ ] Changelog entry added to `Chart.yaml` annotations
- [ ] README.md Parameters section updated (if values changed)
- [ ] Git commit created with descriptive message
- [ ] GitHub Release created with chart .tgz asset
- [ ] `rebuild-index.sh` ran successfully to update gh-pages

---

## Notes

- **Local PostgreSQL:** Uses `readinessProbe: exec: [pg_isready -U paperclip -d paperclip]`
- **Recreate strategy:** Single-replica deployments use `Recreate` strategy (no RollingUpdate)
- **Storage class:** Local Docker Desktop uses `docker-desktop` storage class
- **Multi-replica limitation:** `replicaCount > 1` requires `ReadWriteMany` storage (not available on most OVH classes)
- **ArtifactHub sync:** After GitHub Release, allow 10-30 minutes for ArtifactHub to refresh the index

---

**Test environment:** Docker Desktop K8s  
**Tested by:** [Name]  
**Date:** [Date]  
**Status:** [PASS/FAIL]
