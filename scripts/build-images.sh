#!/usr/bin/env bash
# =============================================================================
# build-images.sh — the two images the clean reinstall needs (ADR-158 §0-ter.5)
# =============================================================================
#   1. docker.io/ileonelperea/paperclip:<PAPERCLIP_TAG>
#      = official ghcr.io/paperclipai/paperclip:2026.1005.0 (by digest) + the
#        kubernetes sandbox provider compiled (image/Dockerfile). PRIVATE is fine:
#        the paperclip namespace gets regcred through ESO (values-ovh.yaml).
#   2. docker.io/ileonelperea/agent-runtime-claude:<RUNTIME_TAG> (+ its base)
#      = upstream docker/agent-runtime at the SAME tag, built with upstream's own
#        buildx-bake.hcl (ghcr.io/paperclipai/agent-runtime-* answers 404 to
#        anonymous pulls, measured 2026-10-08). PRIVATE like every image of ours
#        (decided 2026-10-09: nothing published): forced kubernetes mode has no
#        PAPERCLIP_K8S_* for pull secrets, so the chart gives every sandbox
#        namespace regcred plus the provider's ServiceAccount carrying it
#        (kubernetesExecution.sandboxImagePullSecret). New repositories of this
#        account are born private (0 public repositories, measured 2026-10-09);
#        step 4 refuses to continue if this one is not.
#
# Multi-arch, the Alebrije standard (docker platform guard): linux/amd64 (the OVH
# node) + linux/arm64 (local M-series), with registry build cache (M160). Never a
# floating tag: :latest is refused (M216) and values-ovh.yaml takes the DIGESTS.
#
# Usage (from the chart root, logged in to Docker Hub as ileonelperea):
#   bash scripts/build-images.sh                    # build + push + print digests
#   bash scripts/build-images.sh --escribir-values  # also write the digests into values-ovh.yaml
# =============================================================================
set -euo pipefail

UPSTREAM_REPO="https://github.com/paperclipai/paperclip.git"
UPSTREAM_TAG="v2026.1005.0"
UPSTREAM_COMMIT="467125f"          # measured 2026-10-08 (git log -1 of the tag)
REGISTRY="docker.io/ileonelperea"
PAPERCLIP_TAG="${PAPERCLIP_TAG:-2026.1005.0-k8s.1}"
RUNTIME_TAG="${RUNTIME_TAG:-2026.1005.0-1}"
WRITE_VALUES=0
[[ "${1:-}" == "--escribir-values" ]] && WRITE_VALUES=1

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for t in "$PAPERCLIP_TAG" "$RUNTIME_TAG"; do
  [[ "$t" == "latest" || -z "$t" ]] && { echo "ERROR: tag vacío o latest (M216)." >&2; exit 1; }
done
command -v jq >/dev/null || { echo "ERROR: falta jq." >&2; exit 1; }
docker buildx version >/dev/null || { echo "ERROR: falta docker buildx." >&2; exit 1; }

digest_of() { docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r .digest; }

echo "[1/5] Paperclip ${UPSTREAM_TAG} (fuente de las imágenes de runtime)..."
WORK="$(mktemp -d)"
trap '[[ -n "${WORK:-}" && -d "$WORK" && "$WORK" == /*/tmp.* ]] && rm -rf -- "$WORK"' EXIT
git clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$WORK/pc" 2>/dev/null
got="$(git -C "$WORK/pc" rev-parse --short=7 HEAD)"
[[ "$got" == "$UPSTREAM_COMMIT" ]] || { echo "ERROR: ${UPSTREAM_TAG} apunta a ${got}, se esperaba ${UPSTREAM_COMMIT}." >&2; exit 1; }
echo "      ${UPSTREAM_TAG} = ${got}"

echo "[2/5] agent-runtime base + claude (buildx-bake de upstream, linux/amd64+arm64, push)..."
# bake reads REGISTRY and VERSION from the environment (HCL variables).
( cd "$WORK/pc" && export REGISTRY && export VERSION="$RUNTIME_TAG" && \
    docker buildx bake -f docker/agent-runtime/buildx-bake.hcl --push \
      --set "*.platform=linux/amd64,linux/arm64" \
      --set "base.cache-from=type=registry,ref=${REGISTRY}/agent-runtime-base:buildcache" \
      --set "base.cache-to=type=registry,ref=${REGISTRY}/agent-runtime-base:buildcache,mode=max" \
      --set "claude.cache-from=type=registry,ref=${REGISTRY}/agent-runtime-claude:buildcache" \
      --set "claude.cache-to=type=registry,ref=${REGISTRY}/agent-runtime-claude:buildcache,mode=max" \
      base claude )
RUNTIME_REF="${REGISTRY}/agent-runtime-claude:${RUNTIME_TAG}"
RUNTIME_DIGEST="$(digest_of "$RUNTIME_REF")"
echo "      ${RUNTIME_REF}@${RUNTIME_DIGEST}"

echo "[3/5] paperclip + proveedor kubernetes compilado (image/Dockerfile, linux/amd64+arm64, push)..."
PAPERCLIP_REF="${REGISTRY}/paperclip:${PAPERCLIP_TAG}"
docker buildx build --platform linux/amd64,linux/arm64 \
  --cache-from "type=registry,ref=${REGISTRY}/paperclip:buildcache" \
  --cache-to "type=registry,ref=${REGISTRY}/paperclip:buildcache,mode=max" \
  --push -t "$PAPERCLIP_REF" "$CHART_DIR/image"
PAPERCLIP_DIGEST="$(digest_of "$PAPERCLIP_REF")"
echo "      ${PAPERCLIP_REF}@${PAPERCLIP_DIGEST}"

echo "[3b/5] Escaneo ANTES de usarlas (trivy, con tus credenciales de Docker): secretos en"
echo "       cualquier capa y vulnerabilidades CRÍTICAS con arreglo. Cualquier hallazgo detiene"
echo "       todo; una excepción la decide el dueño, nunca este guion."
command -v trivy >/dev/null || { echo "ERROR: falta trivy (brew install trivy)." >&2; exit 1; }
for ref in "${RUNTIME_REF}@${RUNTIME_DIGEST}" "${PAPERCLIP_REF}@${PAPERCLIP_DIGEST}"; do
  trivy image --quiet --scanners secret --exit-code 1 "$ref" \
    || { echo "ERROR: trivy encontró secretos en ${ref}: no se escriben sus digests ni se instala." >&2; exit 1; }
  trivy image --quiet --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 "$ref" \
    || { echo "ERROR: vulnerabilidades CRÍTICAS con arreglo en ${ref}: decide el dueño antes de instalarla." >&2; exit 1; }
  echo "      ${ref}: sin secretos y sin CRÍTICAS con arreglo"
done

echo "[4/5] ¿Las imágenes quedaron PRIVADAS? (el digest ya existe: lo leyó imagetools con tus credenciales)"
for repo in agent-runtime-base agent-runtime-claude paperclip; do
  anon_token="$(curl -sS --max-time 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ileonelperea/${repo}:pull" | jq -r .token)"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -I \
    -H "Authorization: Bearer ${anon_token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/ileonelperea/${repo}/manifests/${RUNTIME_TAG}")"
  [[ "$repo" == "paperclip" ]] && code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -I \
    -H "Authorization: Bearer ${anon_token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://registry-1.docker.io/v2/ileonelperea/${repo}/manifests/${PAPERCLIP_TAG}")"
  if [[ "$code" != "401" ]]; then
    echo "ERROR: pull anónimo de ileonelperea/${repo} responde ${code} (se esperaba 401): el repositorio NO es privado." >&2
    echo "       Ponlo privado en Docker Hub ANTES de seguir; nada de este guion publica imágenes." >&2
    exit 1
  fi
  echo "      ileonelperea/${repo}: pull anónimo → 401 (privado)"
done

echo "[5/5] Valores para values-ovh.yaml:"
echo "      image.digest: ${PAPERCLIP_DIGEST}"
echo "      kubernetesExecution.adapters[0].runtimeImage: ${RUNTIME_REF}@${RUNTIME_DIGEST}"
if [[ "$WRITE_VALUES" == "1" ]]; then
  PAPERCLIP_DIGEST="$PAPERCLIP_DIGEST" RUNTIME_IMAGE="${RUNTIME_REF}@${RUNTIME_DIGEST}" PAPERCLIP_TAG="$PAPERCLIP_TAG" \
  python3 - "$CHART_DIR/values-ovh.yaml" <<'PY'
import os, re, sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
def sub_once(pattern, repl):
    global s
    new, n = re.subn(pattern, repl, s, count=1, flags=re.M)
    if n != 1:
        sys.exit(f"ERROR: no encontré una sola vez: {pattern}")
    s = new
sub_once(r'^(  tag: )"[^"]*"(\n  # Filled by scripts/build-images\.sh \(prints the pushed digest\)\.\n  digest: )"[^"]*"',
         rf'\1"{os.environ["PAPERCLIP_TAG"]}"\2"{os.environ["PAPERCLIP_DIGEST"]}"')
sub_once(r'^(      runtimeImage: )"[^"]*"', rf'\1"{os.environ["RUNTIME_IMAGE"]}"')
open(path, "w", encoding="utf-8").write(s)
print("      values-ovh.yaml actualizado (revisa el diff y commitéalo).")
PY
fi
