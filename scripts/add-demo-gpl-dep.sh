#!/usr/bin/env bash
# Add a real GPL-licensed npm package to nodegoat-manifests/ to demo the
# dependency-review-action license gate. Idempotent — safe to run multiple times.
#
# Uses 'gpl-2.0-licensed@1.0.0' — a real npm package published specifically as a
# fixture for license policy testing. dep-review queries GitHub's npm metadata
# (not the local lockfile's "license" field), so a real published package is
# required to trigger the deny-licenses gate.
#
# Usage:
#   scripts/add-demo-gpl-dep.sh
#
# Then:
#   git add nodegoat-manifests/
#   git commit -m "demo: add GPL-2.0 dep to trigger dep-review gate"
#   git push
#
# Expected on the next PR: dependency-review fails with
#   Denied: gpl-2.0-licensed@1.0.0 (GPL-2.0-only)

set -euo pipefail

PKG_NAME="gpl-2.0-licensed"
PKG_VERSION="1.0.0"
PKG_LICENSE="GPL-2.0-only"
PKG_RESOLVED="https://registry.npmjs.org/${PKG_NAME}/-/${PKG_NAME}-${PKG_VERSION}.tgz"
PKG_INTEGRITY="sha512-KNol5xR+cOQ8mST4GyymwM04GaJhDzC9DZJlGrz3sIBT22Ng49qBRlLmOdVDsvsrpu6xe0fmlqMO+uEDHq0G2Q=="

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_JSON="$ROOT/nodegoat-manifests/package.json"
LOCK_JSON="$ROOT/nodegoat-manifests/package-lock.json"

command -v jq >/dev/null || { echo "Install jq: brew install jq"; exit 1; }
[ -f "$PKG_JSON" ] && [ -f "$LOCK_JSON" ] || {
  echo "Missing $PKG_JSON or $LOCK_JSON. Run 'just sync-manifests' first."
  exit 1
}

echo "Adding $PKG_NAME@$PKG_VERSION ($PKG_LICENSE) to nodegoat-manifests/ (idempotent)..."

# package.json — assignment is idempotent (overwrites or creates)
jq --arg n "$PKG_NAME" --arg v "$PKG_VERSION" \
   '.dependencies[$n] = $v' \
   "$PKG_JSON" > "$PKG_JSON.tmp" && mv "$PKG_JSON.tmp" "$PKG_JSON"

# package-lock.json — handles both npm lockfile v1 (.dependencies) and v2/v3 (.packages)
jq --arg n "$PKG_NAME" --arg v "$PKG_VERSION" --arg l "$PKG_LICENSE" \
   --arg r "$PKG_RESOLVED" --arg i "$PKG_INTEGRITY" '
def entry($n; $v; $l; $r; $i):
  {
    "version": $v,
    "resolved": $r,
    "integrity": $i,
    "license": $l
  };

# v2/v3: .packages root deps + .packages."node_modules/<name>"
(if has("packages") then
  .packages[""].dependencies = ((.packages[""].dependencies // {}) | .[$n] = $v) |
  .packages["node_modules/" + $n] = entry($n; $v; $l; $r; $i)
 else . end)
|
# v1 (or v2 backwards-compat): .dependencies."<name>"
(if has("dependencies") then
  .dependencies[$n] = entry($n; $v; $l; $r; $i)
 else . end)
' "$LOCK_JSON" > "$LOCK_JSON.tmp" && mv "$LOCK_JSON.tmp" "$LOCK_JSON"

echo "Done. Verify:"
echo "  jq '.dependencies.\"$PKG_NAME\"' nodegoat-manifests/package.json"
echo "  jq '.packages.\"node_modules/$PKG_NAME\".license // .dependencies.\"$PKG_NAME\".license' nodegoat-manifests/package-lock.json"
