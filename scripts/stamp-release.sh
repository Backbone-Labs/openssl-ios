#!/usr/bin/env bash
# Points Package.swift at a published release asset by filling in
# releaseVersion and releaseChecksum.
#
# Only the release commit is stamped (see .github/workflows/release.yml). That
# commit is reachable from its tag alone, so main keeps both values empty and
# always builds from the local build/OpenSSLCrypto.xcframework.
#
# Usage: scripts/stamp-release.sh <version> <checksum>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/Package.swift"
version="${1:-}"
checksum="${2:-}"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version '$version' is not X.Y.Z" >&2
  exit 1
fi
if ! [[ "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: checksum '$checksum' is not a SwiftPM checksum (64 lowercase hex digits)" >&2
  exit 1
fi
if ! grep -q '^let releaseVersion = ""$' "$MANIFEST" || ! grep -q '^let releaseChecksum = ""$' "$MANIFEST"; then
  echo "error: Package.swift is already stamped, or its release constants were renamed." >&2
  exit 1
fi

sed -i '' \
  -e "s/^let releaseVersion = \"\"$/let releaseVersion = \"$version\"/" \
  -e "s/^let releaseChecksum = \"\"$/let releaseChecksum = \"$checksum\"/" \
  "$MANIFEST"

echo "Stamped Package.swift for $version"
