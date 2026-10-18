#!/usr/bin/env bash
set -euo pipefail

# Detects project category, git remote owner/repo, branches, and latest tags -> JSON

REMOTE_URL="$(git remote get-url origin 2>/dev/null || echo "")"
REPO="$(echo "$REMOTE_URL" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

LATEST_STABLE="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | grep -v '-' | sort -V | tail -n1 || true)"
LATEST_RC="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*-rc.*' | sort -V | tail -n1 || true)"

CATEGORY="webapp-api"
if grep -rnq "UseWindowsService\|Microsoft.Extensions.Hosting.WindowsServices" . --include="*.cs" --include="*.csproj" 2>/dev/null; then
  CATEGORY="windows-service"
elif [[ -f "Dockerfile" || -f "docker-compose.yml" ]]; then
  CATEGORY="docker"
elif find . -maxdepth 3 -name "*.csproj" -exec grep -q "<OutputType>Exe</OutputType>" {} + 2>/dev/null; then
  CATEGORY="cli"
fi

cat <<EOF
{
  "repo": "${REPO}",
  "currentBranch": "${BRANCH}",
  "category": "${CATEGORY}",
  "latestStableTag": "${LATEST_STABLE:-none}",
  "latestRcTag": "${LATEST_RC:-none}"
}
EOF
