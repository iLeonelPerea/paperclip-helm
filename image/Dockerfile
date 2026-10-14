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
ARG BUILDPLATFORM
ARG TARGETPLATFORM
# The provider's own Alebrije patches (image/patches/*.patch whose files are ALL
# under the provider's directory) go in here, BEFORE it is compiled: the server
# runs this dist/. The final stage applies every patch again to /app, so the
# shipped src/ matches this dist/. A patch that mixes provider files with others
# stops the build instead of leaving dist/ and src/ out of step.
#   - 0002-kubernetes-job-backend-exec.patch: the job backend's pod idles (sleep
#     infinity, like the sandbox-cr pod) and paperclip-server execs every command
#     into it. Upstream's job backend ignored the command and only waited for a
#     one-shot shim that has no spec (/run/paperclip/runtime-command.json is never
#     mounted, the shim exits 2), so no agent run got past the server's per-run Git
#     probe: «Could not read execution-target Git context» (measured 2026-10-13 on
#     pi-k3s; the same code in v2026.1012.0).
COPY patches/ /tmp/alebrije-patches/
WORKDIR /app
RUN set -eu; \
    rel="${PROVIDER_DIR#/app/}/"; \
    for p in /tmp/alebrije-patches/*.patch; do \
      files="$(git apply --numstat "$p" | awk '{print $3}')"; \
      total="$(printf '%s\n' "$files" | awk 'NF {n++} END {print n + 0}')"; \
      inside="$(printf '%s\n' "$files" | awk -v r="$rel" 'index($0, r) == 1 {n++} END {print n + 0}')"; \
      [ "$inside" -gt 0 ] || continue; \
      [ "$inside" -eq "$total" ] || { echo "ERROR: $(basename "$p") mixes provider files with others" >&2; exit 1; }; \
      git apply --check "$p"; \
      git apply "$p"; \
      echo "applied to the provider: $(basename "$p")"; \
    done; \
    rm -rf /tmp/alebrije-patches
WORKDIR ${PROVIDER_DIR}
# NODE_ENV=production in the image would make pnpm skip typescript (a devDependency).
# The provider's unit tests (vitest, a devDependency too) run against the patched
# source once, on the build's own platform: they are platform-independent
# TypeScript, and the other platform builds under emulation.
RUN set -eu; \
    NODE_ENV=development pnpm install --ignore-workspace --no-lockfile; \
    mkdir -p node_modules/@paperclipai; \
    ln -sfn /app/packages/plugins/sdk node_modules/@paperclipai/plugin-sdk; \
    pnpm exec tsc -p tsconfig.json; \
    test -f dist/manifest.js || { echo "ERROR: kubernetes provider is missing dist/manifest.js after build" >&2; exit 1; }; \
    if [ "$TARGETPLATFORM" = "$BUILDPLATFORM" ]; then \
      NODE_ENV=development pnpm exec vitest run; \
    else \
      echo "provider unit tests: run on ${BUILDPLATFORM}, not under emulation for ${TARGETPLATFORM}"; \
    fi

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
# an upstream file moved, instead of shipping a stale copy of it.
# The server runs the COMPILED build (`node … server/dist/index.js`), not src/:
# 2026.1005.0-k8s.3 patched only src/ and its route answered 404 in prod. So
# every patched server/src/*.ts is compiled here with the server's own `tsc -p
# tsconfig.json` (the same compiler and options as upstream's build: compiled
# this way, 4052 of the unchanged files came out byte-identical to the shipped
# dist/) into a sibling folder, so the source maps keep their relative paths,
# and only those modules are copied into dist/. The checks read dist/.
#   - 0001-admin-create-user.patch (ADR-115 Addendum D6, d6-5): POST
#     /api/admin/users lets an instance admin create a user while public sign-up
#     stays closed (PAPERCLIP_AUTH_DISABLE_SIGN_UP=true). Its suite
#     server/src/__tests__/admin-user-create.integration.test.ts runs against
#     src/ or, with PAPERCLIP_TEST_BUILD=dist, against this dist/.
#   - 0002-kubernetes-job-backend-exec.patch: compiled with the provider in the
#     kubernetes-provider stage (see there), where its unit tests run; here it
#     only brings the shipped provider src/ and test/ in line with that dist/.
COPY patches/ /tmp/alebrije-patches/
RUN set -eu; \
    cd /app; \
    applied=0; : > /tmp/alebrije-patched-files; \
    for p in /tmp/alebrije-patches/*.patch; do \
      git apply --check "$p"; \
      git apply "$p"; \
      git apply --numstat "$p" | awk '{print $3}' >> /tmp/alebrije-patched-files; \
      echo "applied $(basename "$p")"; applied=$((applied + 1)); \
    done; \
    [ "$applied" -ge 1 ] || { echo "ERROR: no patch applied from /tmp/alebrije-patches" >&2; exit 1; }; \
    xargs chown node:node < /tmp/alebrije-patched-files; \
    cd /app/server; \
    /app/node_modules/.bin/tsc -p tsconfig.json --outDir dist-alebrije; \
    compiled=0; \
    for src in $(grep -E '^server/src/.*\.ts$' /tmp/alebrije-patched-files | grep -v '/__tests__/' | sort -u); do \
      rel="${src#server/src/}"; rel="${rel%.ts}"; \
      for ext in .js .js.map .d.ts .d.ts.map; do \
        test -f "dist-alebrije/$rel$ext" || { echo "ERROR: tsc emitted no dist-alebrije/$rel$ext" >&2; exit 1; }; \
        install -m 0644 -o node -g node "dist-alebrije/$rel$ext" "dist/$rel$ext"; \
      done; \
      echo "compiled into dist: $rel"; compiled=$((compiled + 1)); \
    done; \
    rm -rf dist-alebrije /tmp/alebrije-patched-files; \
    [ "$compiled" -ge 1 ] || { echo "ERROR: no patched server module was compiled into dist" >&2; exit 1; }; \
    grep -q '"/admin/users", validate(createAdminUserSchema)' dist/routes/access.js \
      || { echo "ERROR: dist/routes/access.js has no POST /admin/users" >&2; exit 1; }; \
    grep -q 'registerAdminUserCreator(' dist/auth/better-auth.js \
      || { echo "ERROR: dist/auth/better-auth.js does not register the user creator" >&2; exit 1; }; \
    grep -q '"sleep infinity"' "${PROVIDER_DIR}/dist/pod-spec-builder.js" \
      || { echo "ERROR: the provider dist/ does not idle the job pod (patch 0002)" >&2; exit 1; }; \
    grep -q 'waitForJobPodRunning(' "${PROVIDER_DIR}/dist/plugin.js" \
      || { echo "ERROR: the provider dist/ does not exec on the job backend (patch 0002)" >&2; exit 1; }; \
    node -e "import('${PROVIDER_DIR}/dist/job-orchestrator.js').then((m) => { if (typeof m.waitForJobPodRunning !== 'function') { console.error('ERROR: the provider dist/ lost waitForJobPodRunning'); process.exit(1); } console.log('patched provider module loads'); }, (e) => { console.error('ERROR: the patched provider module does not load:', e); process.exit(1); })"; \
    cd /app; \
    node --import ./server/node_modules/tsx/dist/loader.mjs -e " \
      Promise.all([import('/app/server/dist/auth/admin-user-creator.js'), import('/app/server/dist/auth/better-auth.js'), import('/app/server/dist/routes/access.js')]) \
        .then(([c, b, a]) => { const ok = typeof c.createUserWithPassword === 'function' && typeof c.registerAdminUserCreator === 'function' && typeof b.createBetterAuthInstance === 'function' && typeof a.accessRoutes === 'function'; \
          if (!ok) { console.error('ERROR: a patched dist module lost an export'); process.exit(1); } console.log('patched dist modules load'); process.exit(0); }, \
          (e) => { console.error('ERROR: a patched dist module does not load:', e); process.exit(1); })"; \
    rm -rf /tmp/alebrije-patches
LABEL io.alebrije.paperclip.base="ghcr.io/paperclipai/paperclip:2026.1005.0" \
      io.alebrije.paperclip.extra="kubernetes sandbox provider compiled in place (ADR-158 §0-ter.5); esbuild rebuilt with Go 1.26.9, proxy-addr 2.0.8, release version in place of the 0.3.1 placeholder; patch 0001 POST /api/admin/users (ADR-115 D6, d6-5), compiled into dist; patch 0002 job backend execs into an idle pod, compiled into the provider dist"
