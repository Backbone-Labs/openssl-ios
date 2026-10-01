#!/usr/bin/env bash
# Builds build/OpenSSLCrypto.xcframework: a static libcrypto for iOS devices
# (arm64) and the arm64 iOS Simulator, from the OpenSSL release pinned in
# scripts/openssl-source.env. The source tarball is checked against the pinned
# SHA-256 before anything is extracted.
#
# Usage:   scripts/build-xcframework.sh
# Output:  build/OpenSSLCrypto.xcframework
#          build/BUILD_INFO.txt   (toolchain, options and per-slice hashes;
#                                  the release workflow publishes it as notes)
#
# The build is repeatable: the same source and the same Xcode give a
# byte-identical (unsigned) xcframework, whatever directory it is built in. The
# fixed --prefix/--openssldir keep build paths out of the binary, ZERO_AR_DATE
# zeroes archive member timestamps, SOURCE_DATE_EPOCH (taken from the tarball)
# replaces the build date OpenSSL embeds, and Info.plist is sorted below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=openssl-source.env
source "$ROOT/scripts/openssl-source.env"

BUILD="$ROOT/build"
DOWNLOADS="$BUILD/downloads"
WORK="$BUILD/work"
XCFRAMEWORK="$BUILD/OpenSSLCrypto.xcframework"
TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
SOURCE_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${TARBALL}"
JOBS="$(sysctl -n hw.ncpu)"

# libcrypto only: the static library has no use for the CLI, tests or man pages.
CONFIGURE_OPTIONS=(no-shared no-tests no-apps no-docs --prefix=/usr/local --openssldir=/usr/local/ssl)

fetch_source() {
  mkdir -p "$DOWNLOADS"
  if [[ ! -f "$DOWNLOADS/$TARBALL" ]]; then
    echo "Downloading $SOURCE_URL"
    curl --fail --location --silent --show-error --output "$DOWNLOADS/$TARBALL.partial" "$SOURCE_URL"
    mv "$DOWNLOADS/$TARBALL.partial" "$DOWNLOADS/$TARBALL"
  fi
  if ! echo "$OPENSSL_SHA256  $DOWNLOADS/$TARBALL" | shasum -a 256 -c - >/dev/null; then
    echo "error: $DOWNLOADS/$TARBALL does not match OPENSSL_SHA256 in scripts/openssl-source.env." >&2
    echo "       Do not update the pin to match. Delete the file and re-download; if it still" >&2
    echo "       differs, check the digest against the upstream release." >&2
    exit 1
  fi
  echo "Verified $TARBALL ($OPENSSL_SHA256)"
}

# build_slice <library identifier> <OpenSSL target> <deployment-target flag>
build_slice() {
  local id="$1" target="$2" min_flag="$3"
  local src="$WORK/$id/src" stage="$WORK/$id/stage"

  rm -rf "${WORK:?}/$id"
  mkdir -p "$src" "$stage"
  tar -xzf "$DOWNLOADS/$TARBALL" -C "$src" --strip-components 1

  echo "Building $id ($target)"
  (
    cd "$src"
    ./Configure "$target" "${CONFIGURE_OPTIONS[@]}" "$min_flag=$IOS_DEPLOYMENT_TARGET"
    make -j"$JOBS" build_libs >/dev/null
    make install_dev DESTDIR="$stage" >/dev/null
  )
}

# check_slice <library identifier> <expected LC_BUILD_VERSION platform number>
# Platform 2 is iOS, 7 is the iOS Simulator. A slice built for the wrong one
# links fine here and fails much later in the consuming app.
check_slice() {
  local id="$1" want_platform="$2"
  local lib="$XCFRAMEWORK/$id/libcrypto.a"
  local platforms minos
  platforms="$(otool -l "$lib" | awk '/cmd LC_BUILD_VERSION/{f=1} f&&$1=="platform"{print $2; f=0}' | sort -u | tr '\n' ' ')"
  minos="$(otool -l "$lib" | awk '/cmd LC_BUILD_VERSION/{f=1} f&&$1=="minos"{print $2; f=0}' | sort -u | tr '\n' ' ')"
  if [[ "$platforms" != "$want_platform " || "$minos" != "$IOS_DEPLOYMENT_TARGET " ]]; then
    echo "error: $id has platform [$platforms] minos [$minos]; expected [$want_platform] [$IOS_DEPLOYMENT_TARGET]" >&2
    exit 1
  fi
}

fetch_source

# Every slice gets the same build date: the newest file time in the tarball.
SOURCE_DATE_EPOCH="$(python3 -c 'import sys,tarfile; print(max(m.mtime for m in tarfile.open(sys.argv[1])))' "$DOWNLOADS/$TARBALL")"
export SOURCE_DATE_EPOCH
export ZERO_AR_DATE=1

build_slice ios-arm64           ios64-xcrun              -mios-version-min
build_slice ios-arm64-simulator iossimulator-arm64-xcrun -mios-simulator-version-min

rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$WORK/ios-arm64/stage/usr/local/lib/libcrypto.a" \
  -headers "$WORK/ios-arm64/stage/usr/local/include" \
  -library "$WORK/ios-arm64-simulator/stage/usr/local/lib/libcrypto.a" \
  -headers "$WORK/ios-arm64-simulator/stage/usr/local/include" \
  -output "$XCFRAMEWORK" >/dev/null

# -create-xcframework lists the slices in no fixed order, so two builds with
# identical libraries can still differ in Info.plist. Sort them.
python3 - "$XCFRAMEWORK/Info.plist" <<'EOF'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    info = plistlib.load(f)
info["AvailableLibraries"].sort(key=lambda library: library["LibraryIdentifier"])
with open(path, "wb") as f:
    plistlib.dump(info, f, sort_keys=True)
EOF

check_slice ios-arm64 2
check_slice ios-arm64-simulator 7

# Xcode copies every static xcframework's Headers/ into one shared
# Build/Products/<config>/include/. A module.modulemap there collides with any
# other xcframework that ships one ("Multiple commands produce
# .../include/module.modulemap"). Consumers #include <openssl/...> textually, so
# nothing needs a module map.
if find "$XCFRAMEWORK" -name 'module.modulemap' | grep -q .; then
  echo "error: $XCFRAMEWORK contains a module.modulemap; see the comment above this check." >&2
  exit 1
fi

{
  echo "OpenSSL:            $OPENSSL_VERSION"
  echo "Source:             $SOURCE_URL"
  echo "Source SHA-256:     $OPENSSL_SHA256"
  echo "Configure options:  ${CONFIGURE_OPTIONS[*]}"
  echo "Deployment target:  iOS $IOS_DEPLOYMENT_TARGET"
  echo "SOURCE_DATE_EPOCH:  $SOURCE_DATE_EPOCH"
  echo "Xcode:              $(xcodebuild -version | tr '\n' ' ' | sed 's/ $//')"
  echo "iPhoneOS SDK:       $(xcrun --sdk iphoneos --show-sdk-version)"
  echo "Simulator SDK:      $(xcrun --sdk iphonesimulator --show-sdk-version)"
  echo "libcrypto.a SHA-256:"
  echo "  ios-arm64:           $(shasum -a 256 "$XCFRAMEWORK/ios-arm64/libcrypto.a" | cut -d' ' -f1)"
  echo "  ios-arm64-simulator: $(shasum -a 256 "$XCFRAMEWORK/ios-arm64-simulator/libcrypto.a" | cut -d' ' -f1)"
} > "$BUILD/BUILD_INFO.txt"

echo
cat "$BUILD/BUILD_INFO.txt"
echo
echo "Built $XCFRAMEWORK"
