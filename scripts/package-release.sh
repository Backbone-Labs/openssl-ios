#!/usr/bin/env bash
# Zips build/OpenSSLCrypto.xcframework for a GitHub Release and prints the
# SwiftPM checksum on stdout.
#
# Run it after signing. The signature lives inside the bundle, so zipping first
# would publish an unsigned artifact under a checksum that SwiftPM accepts.
# If the xcframework is signed, the signature is re-verified from the unzipped
# archive: that copy is what consumers actually get.
#
# Usage:  checksum="$(scripts/package-release.sh)"
# Output: build/OpenSSLCrypto.xcframework.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
ZIP="$BUILD/OpenSSLCrypto.xcframework.zip"

if [[ ! -d "$BUILD/OpenSSLCrypto.xcframework" ]]; then
  echo "error: run scripts/build-xcframework.sh first." >&2
  exit 1
fi

rm -f "$ZIP"
# No resource forks or extended attributes: codesign rejects them in a sealed
# bundle, and quarantine/provenance attributes have no business in the archive.
(cd "$BUILD" && ditto -c -k --keepParent --norsrc --noextattr --noacl OpenSSLCrypto.xcframework "$ZIP")

if codesign --display "$BUILD/OpenSSLCrypto.xcframework" >/dev/null 2>&1; then
  unzipped="$(mktemp -d)"
  trap 'rm -rf "$unzipped"' EXIT
  ditto -x -k "$ZIP" "$unzipped"
  codesign --verify --strict "$unzipped/OpenSSLCrypto.xcframework" >&2
  echo "Signature verified on the unzipped archive." >&2
else
  echo "warning: OpenSSLCrypto.xcframework is not signed." >&2
fi

(cd "$ROOT" && swift package compute-checksum "$ZIP")
