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
# Security fixes on top of the official image (trivy gate of scripts/build-images.sh,
# 2026-10-09: 10 CRITICAL with a fix). Each one fixed at its root, none ignored:
#   - esbuild 0.25.12 / 0.18.20 native binaries built with Go 1.23.12 / 1.20.7
#     (CVE-2024-24790 net/netip, CVE-2025-68121 crypto/tls in their stdlib). tsx
#     loads esbuild at every boot (official CMD: node --import …/tsx/dist/loader.mjs),
#     so they cannot be dropped: the SAME esbuild versions are rebuilt from source
#     with a current Go (stage below) and replace the shipped binaries; same
#     version string, so the JS wrappers accept them.
#   - proxy-addr 2.0.7 (CVE-2026-90711, IP spoofing via IPv4-mapped IPv6 trust
#     subnet) → 2.0.8 from npm, same dependencies, sha512 checked against npm.
#   - tar 6.2.1 inside corepack's pnpm cache (/paperclip/.cache, CVE-2026-59873):
#     the cache is removed (runtime never sees it: /paperclip is the data volume).
#   - @paperclipai/server and paperclipai (CLI) carry the source placeholder
#     version 0.3.1 in package.json (upstream: «the source package.json
#     placeholder», server/src/build-version.ts — the real version is baked
#     separately), so trivy matched advisories fixed in 2026.410/2026.416
#     (GHSA-3xx2-mqjm-hg9x & co). This code IS v2026.1005.0, 2431 commits ahead of
#     v2026.416.0 and 0 behind (GitHub compare, 2026-10-09): the placeholder is
#     set to the real release, as upstream's npm publish does. That also stops the
#     scanner from MISSING an advisory whose range starts above 0.3.1. Nothing at
#     runtime reads it (peer-version-check reads peerDependencies; the reported
#     version comes from PAPERCLIP_BUILD_VERSION / .paperclip-build-version).
#
# Built and pushed only by scripts/build-images.sh (linux/amd64 + linux/arm64).
# =============================================================================
ARG PAPERCLIP_IMAGE=ghcr.io/paperclipai/paperclip:2026.1005.0@sha256:de762433b50d56ed9180fef96a13fa236b37856c5c7a7718e8f19afe3d1e8670
ARG PAPERCLIP_RELEASE=2026.1005.0
ARG PROVIDER_DIR=/app/packages/plugins/sandbox-providers/kubernetes
# Go 1.26.9 (measured in the image config 2026-10-09); fixes both stdlib CVEs.
ARG GO_IMAGE=golang:1.26-alpine@sha256:c95332c2af86b6d89b91bd0500f4b9529ccbd090a0d1855c6d1ceaa142ae8615
ARG ESBUILD_VERSIONS="0.25.12 0.18.20"
ARG PROXY_ADDR_INTEGRITY=sha512-5nnx0yGyVUcY6t9RnWcARWtwT9F1D8O9rt08htPvnd49W1IgZtmLkhu9WfMzQj1cFxjHIO6connUNVW5k7AVyQ==

# Native, cross-compiled (no emulation): modules verified by sum.golang.org.
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS esbuild
ARG TARGETOS
ARG TARGETARCH
ARG ESBUILD_VERSIONS
RUN set -eu; mkdir -p /out; \
    for v in ${ESBUILD_VERSIONS}; do \
      mkdir -p "/tmp/esbuild-$v" && cd "/tmp/esbuild-$v"; \
      go mod init rebuild-esbuild; \
      go get "github.com/evanw/esbuild/cmd/esbuild@v$v"; \
      CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
        go build -trimpath -ldflags='-s -w' -o "/out/esbuild-$v" github.com/evanw/esbuild/cmd/esbuild; \
    done; \
    ls -l /out

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
ARG PAPERCLIP_RELEASE
ARG ESBUILD_VERSIONS
ARG PROXY_ADDR_INTEGRITY
COPY --from=kubernetes-provider ${PROVIDER_DIR}/dist ${PROVIDER_DIR}/dist
WORKDIR ${PROVIDER_DIR}
# Runtime dependencies only (@kubernetes/client-node, zod) + the same SDK link.
# corepack and the pnpm store go to /tmp and leave with this layer.
RUN set -eu; \
    COREPACK_HOME=/tmp/corepack pnpm install --ignore-workspace --no-lockfile --prod --store-dir /tmp/pnpm-store; \
    mkdir -p node_modules/@paperclipai; \
    ln -sfn /app/packages/plugins/sdk node_modules/@paperclipai/plugin-sdk; \
    test -f node_modules/@kubernetes/client-node/package.json; \
    test -f node_modules/@paperclipai/plugin-sdk/dist/index.js; \
    chown -R node:node "${PROVIDER_DIR}"; \
    rm -rf /tmp/corepack /tmp/pnpm-store /paperclip/.cache/node/corepack

# Security fixes (see the header). Every step checks its own result.
COPY --from=esbuild /out/ /tmp/esbuild-rebuilt/
WORKDIR /app
RUN set -eu; \
    replaced=0; \
    for v in ${ESBUILD_VERSIONS}; do \
      for b in /app/node_modules/.pnpm/@esbuild+linux-*@"$v"/node_modules/@esbuild/linux-*/bin/esbuild \
               /app/node_modules/.pnpm/esbuild@"$v"/node_modules/esbuild/bin/esbuild; do \
        [ -f "$b" ] || continue; \
        head -c 4 "$b" | grep -q 'ELF' || continue; \
        install -m 0755 "/tmp/esbuild-rebuilt/esbuild-$v" "$b"; \
        [ "$("$b" --version)" = "$v" ] || { echo "ERROR: $b does not report $v" >&2; exit 1; }; \
        echo "esbuild $v rebuilt: $b"; replaced=$((replaced + 1)); \
      done; \
    done; \
    [ "$replaced" -ge 2 ] || { echo "ERROR: expected to replace >= 2 esbuild binaries, replaced $replaced" >&2; exit 1; }; \
    rm -rf /tmp/esbuild-rebuilt; \
    printf 'const n: number = 41;\nconsole.log(n + 1);\n' > /tmp/tsx-check.ts; \
    [ "$(node --import ./server/node_modules/tsx/dist/loader.mjs /tmp/tsx-check.ts)" = "42" ] \
      || { echo "ERROR: tsx cannot transform TypeScript with the rebuilt esbuild" >&2; exit 1; }; \
    rm -f /tmp/tsx-check.ts; \
    d=/app/node_modules/.pnpm/proxy-addr@2.0.7/node_modules/proxy-addr; \
    test -f "$d/package.json"; \
    cd /tmp; \
    npm_config_cache=/tmp/npm-cache npm pack proxy-addr@2.0.8 --silent >/dev/null; \
    got="$(node -e "process.stdout.write('sha512-' + require('crypto').createHash('sha512').update(require('fs').readFileSync('proxy-addr-2.0.8.tgz')).digest('base64'))")"; \
    [ "$got" = "${PROXY_ADDR_INTEGRITY}" ] || { echo "ERROR: proxy-addr 2.0.8 integrity mismatch" >&2; exit 1; }; \
    rm -rf "$d" && mkdir -p "$d" && tar -xzf proxy-addr-2.0.8.tgz -C "$d" --strip-components=1 --no-same-owner; \
    rm -rf /tmp/proxy-addr-2.0.8.tgz /tmp/npm-cache; \
    [ "$(node -p "require('$d/package.json').version")" = "2.0.8" ]; \
    node -e "const p = require('$d'); if (typeof p.compile !== 'function') process.exit(1)"; \
    for p in /app/server/package.json /app/cli/package.json; do \
      node -e "const fs = require('fs'); const [f, v] = process.argv.slice(1); const j = JSON.parse(fs.readFileSync(f, 'utf8')); if (j.version !== '0.3.1') { console.error('ERROR: ' + f + ' no longer carries the 0.3.1 placeholder (' + j.version + '): review before rewriting'); process.exit(1); } j.version = v; fs.writeFileSync(f, JSON.stringify(j, null, 2) + '\n');" "$p" "${PAPERCLIP_RELEASE}"; \
    done; \
    rm -rf /paperclip/.cache/node/corepack

# Alebrije code patches (image/patches/*.patch, applied in name order). Each one
# must apply cleanly to this exact base: `git apply --check` fails the build when
# an upstream file moved, instead of shipping a stale copy of it. The server is
# TypeScript run by tsx at boot (no compile step), so the patched modules are
# loaded here with the same loader the official CMD uses.
#   - 0001-admin-create-user.patch (ADR-115 Addendum D6, d6-5): POST
#     /api/admin/users lets an instance admin create a user while public sign-up
#     stays closed (PAPERCLIP_AUTH_DISABLE_SIGN_UP=true). Tested against the
#     real Better Auth, access router and an embedded Postgres in its own
#     server/src/__tests__/admin-user-create.integration.test.ts.
COPY patches/ /tmp/alebrije-patches/
RUN set -eu; \
    cd /app; \
    applied=0; \
    for p in /tmp/alebrije-patches/*.patch; do \
      git apply --check "$p"; \
      git apply "$p"; \
      echo "applied $(basename "$p")"; applied=$((applied + 1)); \
    done; \
    [ "$applied" -ge 1 ] || { echo "ERROR: no patch applied from /tmp/alebrije-patches" >&2; exit 1; }; \
    chown node:node server/src/auth/better-auth.ts server/src/routes/access.ts \
      server/src/auth/admin-user-creator.ts server/src/__tests__/admin-user-create.integration.test.ts; \
    node --import ./server/node_modules/tsx/dist/loader.mjs -e " \
      Promise.all([import('/app/server/src/auth/admin-user-creator.ts'), import('/app/server/src/auth/better-auth.ts'), import('/app/server/src/routes/access.ts')]) \
        .then(([c, b, a]) => { const ok = typeof c.createUserWithPassword === 'function' && typeof c.registerAdminUserCreator === 'function' && typeof b.createBetterAuthInstance === 'function' && typeof a.accessRoutes === 'function'; \
          if (!ok) { console.error('ERROR: a patched module lost an export'); process.exit(1); } console.log('patched modules load'); process.exit(0); }, \
          (e) => { console.error('ERROR: a patched module does not load:', e); process.exit(1); })"; \
    rm -rf /tmp/alebrije-patches
LABEL io.alebrije.paperclip.base="ghcr.io/paperclipai/paperclip:2026.1005.0" \
      io.alebrije.paperclip.extra="kubernetes sandbox provider compiled in place (ADR-158 §0-ter.5); esbuild rebuilt with Go 1.26.9, proxy-addr 2.0.8, release version in place of the 0.3.1 placeholder; patch 0001 POST /api/admin/users (ADR-115 D6, d6-5)"
