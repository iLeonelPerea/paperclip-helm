# Paperclip Helm Chart — Operating Rules

## Chart Context

- **Application:** Paperclip AI Agent Orchestrator (Node.js + React + PostgreSQL)
- **Target platforms:** OVH Kubernetes with Traefik ingress, Docker Desktop K8s for local testing
- **ArtifactHub repository:** https://artifacthub.io/packages/helm/paperclip/paperclip
- **GitHub Pages (Helm index):** https://USERNAME.github.io/paperclip-helm
- **Application port:** 3100 (HTTP)
- **Application database port:** 5432 (PostgreSQL)
- **Persistent volume mount:** /paperclip
- **Deployment strategy:** Recreate (single-replica), RollingUpdate (multi-replica with ReadWriteMany storage)

---

## Rules (MANDATORY — no exceptions)

### Rule 1 — Pre-change validation

Before ANY change to the chart:

1. Run `helm lint .` from the chart root
   - Must pass with 0 failures
   - If warnings, evaluate and document (not blockers)

2. Run template rendering with default values
   ```bash
   helm template paperclip . > /tmp/test-defaults.yaml
   ```
   - Must render without errors
   - Output must be valid YAML

3. Run template rendering with all features enabled
   ```bash
   helm template paperclip . \
     --set ingress.enabled=true \
     --set networkPolicy.enabled=true \
     --set podDisruptionBudget.enabled=true \
     > /tmp/test-all-features.yaml
   ```
   - Must render without errors
   - All expected resources present (Ingress, NetworkPolicy x2, PDB)

4. Optional: Run kubeconform on rendered output
   ```bash
   kubeconform -strict /tmp/test-defaults.yaml
   ```

**If any validation fails:** Stop work immediately, identify root cause, and fix before continuing.

---

### Rule 2 — Security requirements

- **NEVER hardcode credentials** in any template, ConfigMap, or Secret manifest
  - Use `secretKeyRef` for all sensitive values
  - External Secrets Operator (ESO) + Vault for production (see Rule 7)
  - Local Docker Desktop uses basic Kubernetes Secrets for testing only

- **Secret validation:** Chart installation must fail if required secrets are not provided
  - `auth.betterAuthSecret` must be validated for minimum length (32 chars)
  - `postgresql.auth.password` must be validated if `postgresql.enabled=true`
  - Add template validation: `{{ required "auth.betterAuthSecret is required" .Values.auth.betterAuthSecret }}`

- **Pod security context:**
  - All containers must run with `seccompProfile: type: RuntimeDefault`
  - Run as non-root user (container image specifies)
  - Set appropriate resource limits and requests

- **Network security:**
  - If `networkPolicy.enabled=true`, deploy 2 policies:
    1. Default-deny all ingress/egress
    2. Allow from ingress controller only
  - Document what namespace ingress controller runs in (typically `ingress-nginx`)

---

### Rule 3 — Values change tracking

When adding, removing, or renaming a values key:

1. Update `values.yaml` with:
   - Clear documentation comment explaining the setting
   - Default value
   - Type hint (e.g., `# string, required`, `# integer, optional`)

2. Update `templates/_helpers.tpl` if a new helper function is needed
   - Example: template to generate database URL from components

3. Update `README.md`:
   - Add entry to Parameters section
   - Include description, type, default, and example

4. Update `TEST-PLAN.md`:
   - Add test scenario for the new setting if it affects deployment behavior
   - Include validation steps

5. Update `Chart.yaml` `annotations.artifacthub.io/changes`:
   - Document what changed: "Added X setting for Y"

6. Commit all updates in a single commit:
   ```bash
   git add Chart.yaml values.yaml templates/_helpers.tpl README.md TEST-PLAN.md
   git commit -m "feat: Add X setting for Y"
   ```

---

### Rule 4 — Template helpers and functions

Use `_helpers.tpl` for:
- Generating consistent labels: `paperclip.labels`
- Generating consistent selectors: `paperclip.selectorLabels`
- Constructing environment variables
- Building complex configuration strings (e.g., database URLs, Vault paths)

**Never** hardcode logic in deployment/statefulset templates — extract to helpers.

---

### Rule 5 — Release process (version bump → GitHub Release → ArtifactHub)

Before creating a GitHub Release:

1. Bump version in `Chart.yaml` (semantic versioning: MAJOR.MINOR.PATCH)
   - MAJOR: Breaking changes to chart (e.g., removing a required value)
   - MINOR: New features (e.g., new values, new resources like PDB)
   - PATCH: Bug fixes, docs updates

2. Add changelog entry to `Chart.yaml` under `annotations.artifacthub.io/changes`:
   ```yaml
   annotations:
     artifacthub.io/changes: |
       - kind: added
         description: Added networkPolicy.enabled feature
       - kind: changed
         description: Bumped Paperclip image to v2.0.0
       - kind: fixed
         description: Fixed PVC permissions for multi-replica deployments
   ```

3. Run complete TEST-PLAN.md on Docker Desktop K8s
   - All phases must PASS
   - Document any skipped tests and why

4. Create commit with version bump:
   ```bash
   git add Chart.yaml
   git commit -m "chore: Bump chart version to X.Y.Z"
   git push origin main
   ```

5. Create GitHub Release from CI or manually:
   ```bash
   gh release create vX.Y.Z --title "Paperclip Helm vX.Y.Z" --notes "See Chart.yaml for changes"
   ```
   - Include `paperclip-X.Y.Z.tgz` asset in the release

6. Update gh-pages branch with new index:
   ```bash
   ./scripts/rebuild-index.sh
   ```
   - This downloads all chart .tgz files from releases
   - Regenerates `index.yaml`
   - Pushes updated index to gh-pages branch
   - ArtifactHub refreshes index within 10-30 minutes

---

### Rule 6 — Features and their configuration

#### PostgreSQL (Embedded)
- Enabled by default (`postgresql.enabled=true`)
- Uses StatefulSet with Recreate strategy
- Requires PVC (uses default storage class)
- Admin user: `postgres`, configured password via `postgresql.auth.password`
- Init container runs database initialization scripts
- Service: `paperclip-postgresql:5432` (ClusterIP, headless optional)

**Test:** Phase 1.3-1.4, Phase 2.4

#### External Database
- Set `postgresql.enabled=false`
- Set `externalDatabase.url` to connection string: `postgresql://user:pass@host:5432/dbname`
- Chart does NOT create database — assumes it exists and is accessible
- Paperclip deployment uses this URL for initialization

**Test:** Phase 0.4, Phase 2.4

#### Ingress
- Disabled by default (`ingress.enabled=false`)
- Class: `traefik` (configurable via `ingress.className`)
- Host: Configurable via `ingress.host` (e.g., `paperclip.yourdomain.com`)
- TLS: Can be enabled (`ingress.tls.enabled=true`) — requires cert-manager or static secret
- Traefik IngressRoute (if applicable) or standard Ingress resource

**Test:** Phase 0.3, Phase 2.1

#### NetworkPolicy
- Disabled by default (`networkPolicy.enabled=false`)
- Creates 2 policies:
  1. Default-deny all ingress/egress
  2. Allow from ingress-nginx namespace (configurable)
- Use on OVH for network segmentation

**Test:** Phase 0.3, Phase 2.2

#### PodDisruptionBudget
- Disabled by default (`podDisruptionBudget.enabled=false`)
- Required for high-availability deployments with `replicaCount > 1`
- `minAvailable: 1` ensures at least one pod survives disruptions

**Test:** Phase 0.3, Phase 2.3

#### Vault Integration (External Secrets Operator)
- Disabled by default (`vault.enabled=false`)
- Requires ESO operator installed in cluster
- Creates ClusterSecretStore (Vault backend) and ExternalSecret
- Stores betterAuth secret and database credentials in Vault
- Use on OVH for centralized secret management

**Configuration required:**
```yaml
vault:
  enabled: true
  address: "http://vault.vault.svc.cluster.local:8200"
  namespace: "vault"
  role: "paperclip"
  auth: "kubernetes"
```

**Test:** Phase 0.5 (dry-run, requires Vault + ESO setup)

---

### Rule 7 — Docker Desktop testing vs. production cluster

**Docker Desktop (local testing):**
- Storage class: `docker-desktop`
- Ingress: Not tested (requires local ingress controller setup)
- NetworkPolicy: Can be tested (no CNI restrictions)
- Vault: Not tested (requires external Vault setup)
- Database: Local PostgreSQL StatefulSet works fine
- Suitable for: Helm template validation, chart logic, PVC/secret mounting

**Production cluster:**
- Storage class: Depends on your cloud provider (e.g., `standard`, `gp2`, or provider-specific)
- Ingress: Use your cluster's ingress class (`traefik`, `nginx`, `gce`, etc.)
- NetworkPolicy: Required for security; CNI (Cilium/Calico/etc.) must support NetworkPolicy
- Vault: ESO + Vault recommended for secrets
- Database: Often external (managed service) — use `postgresql.enabled=false`
- Suitable for: Full feature testing, security validation, production deployment

**Golden rule:** Always test chart logic on Docker Desktop first, then validate on your production cluster.

---

### Rule 8 — Replicacount and storage constraints

- **Single-replica (`replicaCount=1`):** Works with any storage class (ReadWriteOnce or ReadWriteMany)
- **Multi-replica (`replicaCount > 1`):**
  - Requires ReadWriteMany storage class
  - Some cloud providers/clusters may not support ReadWriteMany (check your CSI driver)
  - Test on Docker Desktop with `docker-desktop` (which supports ReadWriteMany)
  - Document in chart: "replicaCount > 1 requires a ReadWriteMany-capable storage class"

**Storage classes to test:**
- Docker Desktop: `docker-desktop` (ReadWriteOnce + ReadWriteMany)
- Production: Depends on your cluster's CSI driver — validate before enabling multi-replica

---

### Rule 9 — Init containers and lifecycle hooks

Paperclip chart uses init containers for:
1. **Database initialization:** Wait for PostgreSQL to be ready before starting Paperclip
2. **Schema setup:** Create tables, indexes, initial data (if applicable)

Init container must:
- Exit with code 0 on success
- Block main container startup if it fails
- Log clearly what it's doing

Main container lifecycle hooks:
- `preStop`: Optional hook to gracefully shut down before pod termination
- `postStart`: Optional hook to register service after startup

---

### Rule 10 — Helm lint and validation errors

**Lint errors (must fix):**
```
1 chart(s) linted, 1 chart(s) failed
```

Common errors:
- `requirements.yaml` missing or malformed
- `Chart.yaml` missing required fields
- Template syntax errors in manifests

**Lint warnings (document, not blockers):**
- "chart name contains uppercase" — style preference
- "values key not referenced" — may be intentional for future use

Fix all linting errors before committing. Warnings can be documented in PR.

---

### Rule 11 — Commit and push process

Push from the chart root directory:

```bash
cd ~/paperclip-helm/  # or wherever you cloned the repo
git add Chart.yaml values.yaml ...
git commit -m "feat: Add X feature"
gh release create vX.Y.Z --title "Paperclip Helm vX.Y.Z"
./scripts/rebuild-index.sh  # Updates gh-pages
```

**NEVER commit:**
- Secrets, credentials, or tokens
- Unvalidated changes (always run lint + template first)
- Breaking changes without major version bump

---

### Rule 12 — Documentation standards

Every chart change must update:
1. `Chart.yaml` — version, annotations
2. `values.yaml` — commented defaults
3. `templates/_helpers.tpl` — new helpers if needed
4. `README.md` — Parameters section
5. `TEST-PLAN.md` — new test scenarios
6. `CLAUDE.md` — this file, if rules change

Commit these updates together in a single commit.

---

## Key file paths

- Chart root: `~/paperclip-helm/` (wherever you cloned the repo)
- Test plan: `TEST-PLAN.md`
- Operating rules: `CLAUDE.md` (this file)
- Chart metadata: `Chart.yaml`
- Default values: `values.yaml`
- Templates: `templates/` directory
- Helper functions: `templates/_helpers.tpl`
- Repository metadata: `artifacthub-repo.yml`
- Index rebuild script: `scripts/rebuild-index.sh`
- README: `README.md`

---

## Troubleshooting

**"helm lint" fails with template errors:**
- Check `Chart.yaml` for syntax errors
- Run `helm template` to see which template is broken
- Fix the template syntax and retry

**"helm template" renders but kubectl rejects it:**
- Run `kubeconform` to validate Kubernetes API versions
- Check resource names for length/character restrictions
- Verify all required fields are present in each resource

**GitHub Release → ArtifactHub lag:**
- ArtifactHub refreshes every 10-30 minutes
- Check `https://artifacthub.io/packages/helm/paperclip/paperclip` for latest version
- If stuck, check gh-pages branch: `git log --oneline -n 5 origin/gh-pages`

**rebuild-index.sh fails:**
- Ensure `gh` CLI is authenticated: `gh auth login`
- Ensure `helm` CLI is installed
- Check that GitHub Release assets include `.tgz` file
- Run with `--dry-run` first to preview changes

---

## Best practices

1. **Always test locally first** on Docker Desktop before pushing to OVH
2. **Use `helm upgrade --dry-run`** to preview changes before applying
3. **Document all values** with type hints and examples
4. **Use semantic versioning** for chart releases (v1.2.3 format)
5. **Keep templates simple** — use helpers for complex logic
6. **Test feature combinations** — e.g., ingress + networkPolicy together
7. **Security-first approach** — assume cluster is multi-tenant
8. **Monitor ArtifactHub** — ensure releases are indexed correctly

---

Last updated: 2026-04-14  
Chart version: See Chart.yaml  
Helm version tested: v3.x+
