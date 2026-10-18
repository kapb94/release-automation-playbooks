#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./cut-release.sh rc [v3.0.0]      -> Creates and pushes next RC tag (e.g. v3.0.0-rc.1, v3.0.0-rc.2)
#   ./cut-release.sh stable [v3.0.0]  -> Creates and pushes stable tag (e.g. v3.0.0)

CHANNEL="${1:-rc}"
BASE_VERSION="${2:-}"

git fetch --tags origin 2>/dev/null || true

if [[ -z "$BASE_VERSION" ]]; then
  LATEST_ANY="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/-.*//' | sort -V | tail -n1 || true)"
  BASE_VERSION="${LATEST_ANY:-v1.0.0}"
fi

if [[ "$BASE_VERSION" != v* ]]; then
  BASE_VERSION="v${BASE_VERSION}"
fi

# Strip any existing -rc.N if user passed full tag
CLEAN_BASE="$(echo "$BASE_VERSION" | cut -d'-' -f1)"

if [[ "$CHANNEL" == "rc" ]]; then
  EXISTING_RCS="$(git tag -l "${CLEAN_BASE}-rc.*" | sed -E "s/^${CLEAN_BASE}-rc\.//" | sort -n | tail -n1 || true)"
  if [[ -z "$EXISTING_RCS" ]]; then
    NEXT_RC=1
  else
    NEXT_RC=$((EXISTING_RCS + 1))
  fi
  TARGET_TAG="${CLEAN_BASE}-rc.${NEXT_RC}"
  MSG="Release Candidate ${TARGET_TAG}"
else
  TARGET_TAG="${CLEAN_BASE}"
  MSG="Official Stable Release ${TARGET_TAG}"
fi

echo "Creating annotated tag: ${TARGET_TAG} (${MSG})"
git tag -a "$TARGET_TAG" -m "$MSG"
git push origin "$TARGET_TAG"
echo "Pushed tag ${TARGET_TAG} to origin."
