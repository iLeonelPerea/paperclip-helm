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
#      The upstream recipe is PATCHED before the build (image/runtime-patches/*.patch,
#      in name order, `git apply --check` first). 0001 builds the shim for each
#      platform: upstream's global `ARG TARGETARCH` shipped an x86-64 shim inside the
#      linux/arm64 image, so every agent run on a Raspberry Pi died with "Exec format
#      error" (measured 2026-10-13, agent-runtime-claude:2026.1005.0-1). It also pins
#      Claude Code instead of @latest. Step 2b checks every platform of the image:
#      the shim's ELF machine and the Claude Code version.
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
PAPERCLIP_TAG="${PAPERCLIP_TAG:-2026.1005.0-k8s.4}"
# 2026.1005.0-1 has the x86-64 shim in its arm64 image (step 2b rejects it); -2 is built with runtime-patches/0001.
RUNTIME_TAG="${RUNTIME_TAG:-2026.1005.0-2}"
# The Claude Code that image/runtime-patches/0001 installs (the reviewed one: what -1 shipped). Step 2b checks it.
CLAUDE_CODE_VERSION="2.1.296"
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
RUNTIME_REF="${REGISTRY}/agent-runtime-claude:${RUNTIME_TAG}"
# A runtime tag is a release: it is built once. Upstream's recipe installs
# @anthropic-ai/claude-code@latest, so rebuilding the SAME tag silently swapped
# the agents' Claude Code and moved the tag (measured 2026-10-11: building
# paperclip k8s.3 rebuilt agent-runtime-claude:2026.1005.0-1, layers 4-5 new;
# the tag was put back on the reviewed digest). To change the runtime, raise
# RUNTIME_TAG. Only "not found" builds it; any other inspect error stops here.
if inspect_err="$(docker buildx imagetools inspect "$RUNTIME_REF" 2>&1 >/dev/null)"; then
  echo "      ${RUNTIME_REF} ya existe: no se reconstruye (para cambiarlo, sube RUNTIME_TAG)."
elif [[ "$inspect_err" == *"not found"* ]]; then
  # The Alebrije patches to upstream's recipe, in name order. A patch that does not apply cleanly to this exact tag
  # stops the build.
  for p in "$CHART_DIR"/image/runtime-patches/*.patch; do
    git -C "$WORK/pc" apply --check "$p"
    git -C "$WORK/pc" apply "$p"
    echo "      parche aplicado: ${p##*/}"
  done
  # bake reads REGISTRY and VERSION from the environment (HCL variables).
  ( cd "$WORK/pc" && export REGISTRY && export VERSION="$RUNTIME_TAG" && \
      docker buildx bake -f docker/agent-runtime/buildx-bake.hcl --push \
        --set "*.platform=linux/amd64,linux/arm64" \
        --set "base.cache-from=type=registry,ref=${REGISTRY}/agent-runtime-base:buildcache" \
        --set "base.cache-to=type=registry,ref=${REGISTRY}/agent-runtime-base:buildcache,mode=max" \
        --set "claude.cache-from=type=registry,ref=${REGISTRY}/agent-runtime-claude:buildcache" \
        --set "claude.cache-to=type=registry,ref=${REGISTRY}/agent-runtime-claude:buildcache,mode=max" \
        base claude )
else
  echo "ERROR: no pude saber si ${RUNTIME_REF} existe: ${inspect_err}" >&2
  exit 1
fi
RUNTIME_DIGEST="$(digest_of "$RUNTIME_REF")"
echo "      ${RUNTIME_REF}@${RUNTIME_DIGEST}"

echo "[2b/5] El runtime en cada plataforma: el shim de su arquitectura y Claude Code ${CLAUDE_CODE_VERSION}..."
# Reads files of the pushed image itself; it never runs the agent binaries, because Claude Code (a Bun binary) aborts
# under the emulation that runs the other architecture here ("qemu: uncaught target signal 6", measured 2026-10-13).
# ELF e_machine at byte 18: 3e00 = x86-64, b700 = aarch64, for the shim and for Claude Code's real binary. It also
# runs for a tag that already exists: a broken release is never reused.
for par in linux/amd64:3e00 linux/arm64:b700; do
  plat="${par%%:*}"; esperado="${par##*:}"
  salida="$(docker run --rm --platform "$plat" --entrypoint /bin/sh "${RUNTIME_REF}@${RUNTIME_DIGEST}" -c '
    for f in /usr/local/bin/paperclip-agent-shim "$(readlink -f "$(command -v claude)")"; do
      od -A n -t x1 -j 18 -N 2 "$f" | tr -d " \n"; echo
    done
    sed -n "s/.*\"version\": *\"\([^\"]*\)\".*/\1/p" /usr/lib/node_modules/@anthropic-ai/claude-code/package.json | head -1')"
  shim="$(sed -n 1p <<<"$salida")"
  claude="$(sed -n 2p <<<"$salida")"
  version="$(sed -n 3p <<<"$salida")"
  [[ "$shim" == "$esperado" ]] \
    || { echo "ERROR: en ${plat} el shim es de otra arquitectura (ELF ${shim}, se esperaba ${esperado})." >&2; exit 1; }
  [[ "$claude" == "$esperado" ]] \
    || { echo "ERROR: en ${plat} Claude Code es de otra arquitectura (ELF ${claude}, se esperaba ${esperado})." >&2; exit 1; }
  [[ "$version" == "$CLAUDE_CODE_VERSION" ]] \
    || { echo "ERROR: en ${plat} Claude Code es «${version}», se esperaba ${CLAUDE_CODE_VERSION}." >&2; exit 1; }
  echo "      ${plat}: shim y Claude Code ${version}, los dos ELF ${shim}"
done

echo "[3/5] paperclip + proveedor kubernetes compilado (image/Dockerfile, linux/amd64+arm64, push)..."
PAPERCLIP_REF="${REGISTRY}/paperclip:${PAPERCLIP_TAG}"
# The same rule as the runtime: a tag is a release, built once. Rebuilding an existing PAPERCLIP_TAG would move it to
# a new digest; a runtime-only release (2026.1005.0-2) ran this step and would have re-pushed k8s.4. To change the
# server, raise PAPERCLIP_TAG. Only "not found" builds it; any other inspect error stops here.
if inspect_err="$(docker buildx imagetools inspect "$PAPERCLIP_REF" 2>&1 >/dev/null)"; then
  echo "      ${PAPERCLIP_REF} ya existe: no se reconstruye (para cambiarlo, sube PAPERCLIP_TAG)."
elif [[ "$inspect_err" == *"not found"* ]]; then
  docker buildx build --platform linux/amd64,linux/arm64 \
    --cache-from "type=registry,ref=${REGISTRY}/paperclip:buildcache" \
    --cache-to "type=registry,ref=${REGISTRY}/paperclip:buildcache,mode=max" \
    --push -t "$PAPERCLIP_REF" "$CHART_DIR/image"
else
  echo "ERROR: no pude saber si ${PAPERCLIP_REF} existe: ${inspect_err}" >&2
  exit 1
fi
PAPERCLIP_DIGEST="$(digest_of "$PAPERCLIP_REF")"
echo "      ${PAPERCLIP_REF}@${PAPERCLIP_DIGEST}"

echo "[3b/5] Escaneo ANTES de usarlas (trivy, con tus credenciales de Docker): secretos en"
echo "       cualquier capa y vulnerabilidades CRÍTICAS con arreglo. Cualquier hallazgo detiene"
echo "       todo; una excepción la decide el dueño, nunca este guion."
command -v trivy >/dev/null || { echo "ERROR: falta trivy (brew install trivy)." >&2; exit 1; }
# Each architecture is its own filesystem (a multi-arch index scanned without
# --platform is ONE of them): both are scanned.
for ref in "${RUNTIME_REF}@${RUNTIME_DIGEST}" "${PAPERCLIP_REF}@${PAPERCLIP_DIGEST}"; do
  for plat in linux/amd64 linux/arm64; do
    trivy image --quiet --platform "$plat" --scanners secret --exit-code 1 "$ref" \
      || { echo "ERROR: trivy encontró secretos en ${ref} (${plat}): no se escriben sus digests ni se instala." >&2; exit 1; }
    trivy image --quiet --platform "$plat" --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 "$ref" \
      || { echo "ERROR: vulnerabilidades CRÍTICAS con arreglo en ${ref} (${plat}): decide el dueño antes de instalarla." >&2; exit 1; }
    echo "      ${ref} (${plat}): sin secretos y sin CRÍTICAS con arreglo"
  done
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
