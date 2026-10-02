#!/usr/bin/env bash
# Builds build/OpenSSLCrypto.xcframework: a static libcrypto for iOS and tvOS
# devices (arm64) and their arm64 simulators, from the OpenSSL release pinned in
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
TVOS_TARGETS_CONF="$ROOT/scripts/openssl-tvos-targets.conf"

# One row per slice: <library identifier> <OpenSSL target> <deployment-target
# flag> <deployment target> <LC_BUILD_VERSION platform>. The identifier must be
# the one -create-xcframework assigns. Platforms: 2 iOS, 7 iOS Simulator,
# 3 tvOS, 8 tvOS Simulator.
SLICES=(
  "ios-arm64            ios64-xcrun               -mios-version-min            $IOS_DEPLOYMENT_TARGET  2"
  "ios-arm64-simulator  iossimulator-arm64-xcrun  -mios-simulator-version-min  $IOS_DEPLOYMENT_TARGET  7"
  "tvos-arm64           tvos64-xcrun              -mtvos-version-min           $TVOS_DEPLOYMENT_TARGET 3"
  "tvos-arm64-simulator tvossimulator-arm64-xcrun -mtvos-simulator-version-min $TVOS_DEPLOYMENT_TARGET 8"
)

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

# build_slice <library identifier> <OpenSSL target> <deployment-target flag> <deployment target>
build_slice() {
  local id="$1" target="$2" min_flag="$3" min_version="$4"
  local src="$WORK/$id/src" stage="$WORK/$id/stage"
  local extra=()
  # Only the tvOS targets need the extra definitions. The iOS slices keep
  # exactly the Configure invocation they have always had.
  [[ "$target" == tvos* ]] && extra=(--config="$TVOS_TARGETS_CONF")

  rm -rf "${WORK:?}/$id"
  mkdir -p "$src" "$stage"
  tar -xzf "$DOWNLOADS/$TARBALL" -C "$src" --strip-components 1

  echo "Building $id ($target)"
  (
    cd "$src"
    ./Configure "$target" ${extra[@]+"${extra[@]}"} "${CONFIGURE_OPTIONS[@]}" "$min_flag=$min_version"
    make -j"$JOBS" build_libs >/dev/null
    make install_dev DESTDIR="$stage" >/dev/null
  )
}

# check_slice <library identifier> <expected platform> <expected deployment target>
# A slice built for the wrong platform or OS version links fine here and fails
# much later in the consuming app.
check_slice() {
  local id="$1" want_platform="$2" want_minos="$3"
  local lib="$XCFRAMEWORK/$id/libcrypto.a"
  local platforms minos
  platforms="$(otool -l "$lib" | awk '/cmd LC_BUILD_VERSION/{f=1} f&&$1=="platform"{print $2; f=0}' | sort -u | tr '\n' ' ')"
  minos="$(otool -l "$lib" | awk '/cmd LC_BUILD_VERSION/{f=1} f&&$1=="minos"{print $2; f=0}' | sort -u | tr '\n' ' ')"
  if [[ "$platforms" != "$want_platform " || "$minos" != "$want_minos " ]]; then
    echo "error: $id has platform [$platforms] minos [$minos]; expected [$want_platform] [$want_minos]" >&2
    exit 1
  fi
}

fetch_source

# Every slice gets the same build date: the newest file time in the tarball.
SOURCE_DATE_EPOCH="$(python3 -c 'import sys,tarfile; print(max(m.mtime for m in tarfile.open(sys.argv[1])))' "$DOWNLOADS/$TARBALL")"
export SOURCE_DATE_EPOCH
export ZERO_AR_DATE=1

create_args=()
for row in "${SLICES[@]}"; do
  read -r id target min_flag min_version _ <<<"$row"
  build_slice "$id" "$target" "$min_flag" "$min_version"
  create_args+=(-library "$WORK/$id/stage/usr/local/lib/libcrypto.a" -headers "$WORK/$id/stage/usr/local/include")
done

rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework "${create_args[@]}" -output "$XCFRAMEWORK" >/dev/null

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

for row in "${SLICES[@]}"; do
  read -r id _ _ min_version platform <<<"$row"
  check_slice "$id" "$platform" "$min_version"
done

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
  echo "                    (tvOS also: --config=scripts/openssl-tvos-targets.conf)"
  echo "Deployment targets: iOS $IOS_DEPLOYMENT_TARGET, tvOS $TVOS_DEPLOYMENT_TARGET"
  echo "SOURCE_DATE_EPOCH:  $SOURCE_DATE_EPOCH"
  echo "Xcode:              $(xcodebuild -version | tr '\n' ' ' | sed 's/ $//')"
  echo "SDKs:               iphoneos $(xcrun --sdk iphoneos --show-sdk-version)," \
    "iphonesimulator $(xcrun --sdk iphonesimulator --show-sdk-version)," \
    "appletvos $(xcrun --sdk appletvos --show-sdk-version)," \
    "appletvsimulator $(xcrun --sdk appletvsimulator --show-sdk-version)"
  echo "libcrypto.a SHA-256:"
  for row in "${SLICES[@]}"; do
    read -r id _ <<<"$row"
    printf "  %-21s %s\n" "$id:" "$(shasum -a 256 "$XCFRAMEWORK/$id/libcrypto.a" | cut -d' ' -f1)"
  done
} > "$BUILD/BUILD_INFO.txt"

echo
cat "$BUILD/BUILD_INFO.txt"
echo
echo "Built $XCFRAMEWORK"
