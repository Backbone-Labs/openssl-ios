#!/usr/bin/env bash
# Checks build/OpenSSLCrypto.xcframework before it is published:
#   1. links scripts/smoke/smoke.c against the iOS and tvOS device slices (link
#      check only; nothing here can run device code),
#   2. links it against both simulator slices and runs each in a simulator of
#      its platform, which tests SHA-256, HMAC, scrypt, base64 and P-256
#      arithmetic against published vectors,
#   3. builds the Swift package itself for all four destinations, so the
#      manifest, the binary target and the privacy-manifest bundle are checked
#      the way a consumer's Xcode sees them.
#
# Usage: scripts/smoke-test.sh   (after scripts/build-xcframework.sh)
#
# For each platform it uses a simulator that is already booted and leaves it
# running. Otherwise it boots the first available iPhone or Apple TV and shuts
# that one down when it finishes.
#
# SMOKE_SKIP_TVOS_RUN=1 skips running the tvOS binary, for a Mac with no tvOS
# Simulator runtime installed; the slice is still linked. CI never sets it: the
# tvOS run is what catches the bignum-limb mistake described in
# scripts/openssl-tvos-targets.conf.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=openssl-source.env
source "$ROOT/scripts/openssl-source.env"

XCFRAMEWORK="$ROOT/build/OpenSSLCrypto.xcframework"
OUT="$ROOT/build/smoke"
CFLAGS=(-Wall -Wextra -O1 "-DEXPECTED_OPENSSL_VERSION=\"$OPENSSL_VERSION\"")

if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "error: $XCFRAMEWORK not found; run scripts/build-xcframework.sh first." >&2
  exit 1
fi
if ! grep -q '^let releaseChecksum = ""$' "$ROOT/Package.swift"; then
  echo "error: Package.swift is stamped for a release, so step 3 would test the published" >&2
  echo "       asset instead of the local build. Run this on main, before stamp-release.sh." >&2
  exit 1
fi
mkdir -p "$OUT"

# link_smoke <sdk> <clang target triple> <slice> <output>
link_smoke() {
  xcrun --sdk "$1" clang -target "$2" "${CFLAGS[@]}" \
    -I "$XCFRAMEWORK/$3/Headers" "$ROOT/scripts/smoke/smoke.c" \
    "$XCFRAMEWORK/$3/libcrypto.a" -o "$4"
  echo "ok   $3 links"
}

BOOTED_HERE=()
trap 'for u in ${BOOTED_HERE[@]+"${BOOTED_HERE[@]}"}; do xcrun simctl shutdown "$u" >/dev/null 2>&1 || true; done' EXIT

# run_in_simulator <runtime marker> <device name prefix> <binary>
run_in_simulator() {
  local marker="$1" prefix="$2" binary="$3" state udid output status
  read -r state udid < <(xcrun simctl list devices available --json | python3 -c '
import json, sys
marker, prefix = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)["devices"]
pool = [d for runtime, ds in devices.items() if marker in runtime for d in ds]
booted = [d for d in pool if d["state"] == "Booted"]
named = [d for d in pool if d["name"].startswith(prefix)]
pick = (booted or named or pool or [None])[0]
print("none -" if pick is None else ("booted " if booted else "shutdown ") + pick["udid"])
' "$marker" "$prefix")
  if [[ "$state" == none ]]; then
    echo "error: no available $prefix simulator ($marker runtime); install that runtime in Xcode." >&2
    return 1
  fi
  if [[ "$state" == shutdown ]]; then
    BOOTED_HERE+=("$udid")
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null

  echo "--   running in $prefix simulator $udid"
  set +e
  output="$(xcrun simctl spawn "$udid" "$binary" 2>&1)"
  status=$?
  set -e
  echo "$output"
  if [[ $status -ne 0 || "$(tail -n 1 <<<"$output")" != "smoke: all checks passed" ]]; then
    echo "error: smoke test failed in the $prefix simulator (exit $status)." >&2
    return 1
  fi
}

# 1. Device slices: link only.
link_smoke iphoneos "arm64-apple-ios$IOS_DEPLOYMENT_TARGET" ios-arm64 "$OUT/smoke-ios-device"
link_smoke appletvos "arm64-apple-tvos$TVOS_DEPLOYMENT_TARGET" tvos-arm64 "$OUT/smoke-tvos-device"

# 2. Simulator slices: link and run.
link_smoke iphonesimulator "arm64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator" ios-arm64-simulator "$OUT/smoke-ios-simulator"
codesign --force --sign - "$OUT/smoke-ios-simulator" 2>/dev/null
run_in_simulator ".SimRuntime.iOS-" "iPhone" "$OUT/smoke-ios-simulator"

link_smoke appletvsimulator "arm64-apple-tvos$TVOS_DEPLOYMENT_TARGET-simulator" tvos-arm64-simulator "$OUT/smoke-tvos-simulator"
codesign --force --sign - "$OUT/smoke-tvos-simulator" 2>/dev/null
if [[ "${SMOKE_SKIP_TVOS_RUN:-}" == 1 ]]; then
  echo "warning: SMOKE_SKIP_TVOS_RUN=1, so tvos-arm64-simulator was linked but NOT run." >&2
else
  run_in_simulator ".SimRuntime.tvOS-" "Apple TV" "$OUT/smoke-tvos-simulator"
fi

# 3. The package as a consumer resolves it.
for destination in 'generic/platform=iOS' 'generic/platform=iOS Simulator' \
                   'generic/platform=tvOS' 'generic/platform=tvOS Simulator'; do
  (cd "$ROOT" && xcodebuild build -quiet \
    -scheme OpenSSLCrypto \
    -destination "$destination" \
    -derivedDataPath "$ROOT/build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO)
  echo "ok   package builds for $destination"
done
