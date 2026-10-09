# =============================================================================
# Paperclip + the kubernetes sandbox provider, compiled (ADR-158 §0-ter.5).
#
# The official image ships packages/plugins/sandbox-providers/kubernetes as SOURCE
# only; at boot a self-hosted instance auto-installs that provider only when its
# dist/ exists (server/src/services/bundled-plugins.ts, SELF_HOSTED_AUTO_INSTALL_KEYS
# = ["kubernetes"]), otherwise it logs «bundle not present» and agents cannot run
# in sandboxes. Upstream compiles it only in its `cloud` target, and only for
# CLOUD_BUNDLED_PLUGINS="daytona".
#
# Why it is compiled IN PLACE (/app/packages/plugins/sandbox-providers/kubernetes)
# and not in a clean directory — measured on the first attempt (2026-10-08):
#   - its tsconfig.json extends "../../../../tsconfig.json" (the monorepo root,
#     present in the image as /app/tsconfig.json + /app/tsconfig.base.json);
#   - it imports @paperclipai/plugin-sdk, a workspace package it does not declare
#     (the sandbox providers are excluded from the pnpm workspace on purpose). The
#     image already carries the SDK BUILT at /app/packages/plugins/sdk/dist, so the
#     provider is linked to exactly the SDK this server runs — at build time and
#     at run time (the compiled worker imports it).
# Built from a clean directory it fails with TS5083 «Cannot read file
# '/tsconfig.json'» and TS2307 «Cannot find module '@paperclipai/plugin-sdk'».
#
# Built and pushed only by scripts/build-images.sh (linux/amd64 + linux/arm64).
# =============================================================================
ARG PAPERCLIP_IMAGE=ghcr.io/paperclipai/paperclip:2026.1005.0@sha256:de762433b50d56ed9180fef96a13fa236b37856c5c7a7718e8f19afe3d1e8670
ARG PROVIDER_DIR=/app/packages/plugins/sandbox-providers/kubernetes

FROM ${PAPERCLIP_IMAGE} AS kubernetes-provider
ARG PROVIDER_DIR
WORKDIR ${PROVIDER_DIR}
# NODE_ENV=production in the image would make pnpm skip typescript (a devDependency).
RUN set -eu; \
    NODE_ENV=development pnpm install --ignore-workspace --no-lockfile; \
    mkdir -p node_modules/@paperclipai; \
    ln -sfn /app/packages/plugins/sdk node_modules/@paperclipai/plugin-sdk; \
    pnpm exec tsc -p tsconfig.json; \
    test -f dist/manifest.js || { echo "ERROR: kubernetes provider is missing dist/manifest.js after build" >&2; exit 1; }

FROM ${PAPERCLIP_IMAGE}
ARG PROVIDER_DIR
COPY --from=kubernetes-provider ${PROVIDER_DIR}/dist ${PROVIDER_DIR}/dist
WORKDIR ${PROVIDER_DIR}
# Runtime dependencies only (@kubernetes/client-node, zod) + the same SDK link.
RUN set -eu; \
    pnpm install --ignore-workspace --no-lockfile --prod; \
    mkdir -p node_modules/@paperclipai; \
    ln -sfn /app/packages/plugins/sdk node_modules/@paperclipai/plugin-sdk; \
    test -f node_modules/@kubernetes/client-node/package.json; \
    test -f node_modules/@paperclipai/plugin-sdk/dist/index.js; \
    chown -R node:node "${PROVIDER_DIR}"
WORKDIR /app
LABEL io.alebrije.paperclip.base="ghcr.io/paperclipai/paperclip:2026.1005.0" \
      io.alebrije.paperclip.extra="kubernetes sandbox provider compiled in place (ADR-158 §0-ter.5)"
