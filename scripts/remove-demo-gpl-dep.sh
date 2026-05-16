#!/usr/bin/env bash
# Remove the fake GPL-3.0 demo package from nodegoat-manifests/.
# Idempotent — safe to run even if the package isn't there.
#
# Usage:
#   scripts/remove-demo-gpl-dep.sh

set -euo pipefail

PKG_NAME="gpl-2.0-licensed"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_JSON="$ROOT/nodegoat-manifests/package.json"
LOCK_JSON="$ROOT/nodegoat-manifests/package-lock.json"

command -v jq >/dev/null || { echo "Install jq: brew install jq"; exit 1; }
[ -f "$PKG_JSON" ] && [ -f "$LOCK_JSON" ] || {
  echo "Missing $PKG_JSON or $LOCK_JSON. Nothing to remove."
  exit 0
}

echo "Removing $PKG_NAME from nodegoat-manifests/ (idempotent)..."

# package.json — del() is a no-op on missing keys
jq --arg n "$PKG_NAME" 'del(.dependencies[$n])' \
   "$PKG_JSON" > "$PKG_JSON.tmp" && mv "$PKG_JSON.tmp" "$PKG_JSON"

# package-lock.json — clean both v1 and v2/v3 locations
jq --arg n "$PKG_NAME" '
# v2/v3: remove from .packages.""."dependencies" and the dedicated entry
(if has("packages") then
  (if .packages[""].dependencies? then
     .packages[""].dependencies = del(.packages[""].dependencies[$n])
   else . end) |
  del(.packages["node_modules/" + $n])
 else . end)
|
# v1 (or v2 backwards-compat): remove from root .dependencies
(if has("dependencies") then
  del(.dependencies[$n])
 else . end)
' "$LOCK_JSON" > "$LOCK_JSON.tmp" && mv "$LOCK_JSON.tmp" "$LOCK_JSON"

echo "Done. Verify (both should print null):"
echo "  jq '.dependencies.\"$PKG_NAME\"' nodegoat-manifests/package.json"
echo "  jq '.packages.\"node_modules/$PKG_NAME\" // .dependencies.\"$PKG_NAME\"' nodegoat-manifests/package-lock.json"
