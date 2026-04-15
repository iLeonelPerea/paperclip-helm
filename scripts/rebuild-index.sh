#!/usr/bin/env bash
#
# rebuild-index.sh - Regenerate Helm repository index from GitHub Releases
#
# Rebuilds the gh-pages branch index.yaml from scratch by downloading all
# .tgz assets from GitHub Releases. Use when:
#   - index.yaml is out of sync with releases
#   - ArtifactHub shows broken/missing versions
#   - After deleting orphaned tags
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - helm CLI installed
#   - Git repo with push access to gh-pages branch
#
# Usage:
#   ./scripts/rebuild-index.sh [--dry-run]
#

set -euo pipefail

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "USERNAME/paperclip-helm")"
BASE_URL="https://$(echo "${REPO}" | cut -d'/' -f1 | tr '[:upper:]' '[:lower:]').github.io/paperclip-helm/charts"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "=== DRY RUN MODE ==="
fi

# Ensure we're in the repo root
if [[ ! -f Chart.yaml ]]; then
  echo "ERROR: Run this script from the chart root directory"
  exit 1
fi

CHART_NAME=$(grep '^name:' Chart.yaml | awk '{print $2}')
echo "Chart: ${CHART_NAME}"
echo "Repo:  ${REPO}"
echo "URL:   ${BASE_URL}"
echo ""

# Create temp working directory
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
mkdir -p "${WORK_DIR}/charts"

echo "=== Step 1: Downloading chart packages from all GitHub Releases ==="
RELEASE_COUNT=0
for tag in $(gh release list --repo "${REPO}" --limit 100 --json tagName -q '.[].tagName' | sort -V); do
  echo -n "  ${tag}: "
  if gh release download "${tag}" \
    --repo "${REPO}" \
    --pattern "*.tgz" \
    --dir "${WORK_DIR}/charts/" 2>/dev/null; then
    echo "OK"
    RELEASE_COUNT=$((RELEASE_COUNT + 1))
  else
    echo "SKIP (no .tgz asset)"
  fi
done

echo ""
echo "=== Step 2: Downloaded ${RELEASE_COUNT} chart package(s) ==="
ls -lh "${WORK_DIR}/charts/"*.tgz 2>/dev/null || {
  echo "ERROR: No chart packages found in any release!"
  exit 1
}

echo ""
echo "=== Step 3: Generating index.yaml ==="
helm repo index "${WORK_DIR}/charts" --url "${BASE_URL}"

echo ""
echo "=== Step 4: Verifying index.yaml ==="
echo "Versions found:"
grep 'version:' "${WORK_DIR}/charts/index.yaml" | sed 's/^/  /'
echo ""

ENTRY_COUNT=$(grep -c '  version:' "${WORK_DIR}/charts/index.yaml" || echo "0")
echo "Total: ${ENTRY_COUNT} version(s)"

if [[ "${ENTRY_COUNT}" -eq 0 ]]; then
  echo "ERROR: No entries in generated index.yaml!"
  exit 1
fi

if [[ "${DRY_RUN}" == true ]]; then
  echo ""
  echo "=== DRY RUN: Would update gh-pages with ==="
  cat "${WORK_DIR}/charts/index.yaml"
  echo ""
  echo "=== DRY RUN: No changes made ==="
  exit 0
fi

echo ""
echo "=== Step 5: Updating gh-pages branch ==="
CURRENT_BRANCH=$(git branch --show-current)

git stash --include-untracked 2>/dev/null || true

if git rev-parse --verify origin/gh-pages &>/dev/null; then
  git checkout gh-pages
  rm -rf charts index.yaml
else
  git checkout --orphan gh-pages
  git rm -rf . 2>/dev/null || true
fi

mkdir -p charts
cp "${WORK_DIR}/charts/"*.tgz charts/
cp "${WORK_DIR}/charts/index.yaml" .

git checkout main -- artifacthub-repo.yml 2>/dev/null || true

git add index.yaml charts/ artifacthub-repo.yml 2>/dev/null || true
git commit -m "Rebuild index.yaml from scratch (${ENTRY_COUNT} releases)" || {
  echo "No changes to commit"
}
git push origin gh-pages

git checkout "${CURRENT_BRANCH}"
git stash pop 2>/dev/null || true

echo ""
echo "=== Done! gh-pages updated with ${ENTRY_COUNT} chart version(s) ==="
echo "ArtifactHub should refresh within 10-30 minutes"
