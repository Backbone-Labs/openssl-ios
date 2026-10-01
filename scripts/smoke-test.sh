#!/usr/bin/env bash
# Checks build/OpenSSLCrypto.xcframework before it is published:
#   1. links scripts/smoke/smoke.c against the device slice (link check only;
#      nothing here can run device code),
#   2. links it against the simulator slice and runs it in an iOS Simulator,
#      which tests SHA-256, HMAC, scrypt, base64 and P-256 arithmetic against
#      published vectors,
#   3. builds the Swift package itself for both platforms, so the manifest, the
#      binary target and the privacy-manifest bundle are checked the way a
#      consumer's Xcode sees them.
#
# Usage: scripts/smoke-test.sh   (after scripts/build-xcframework.sh)
#
# Uses a simulator that is already booted and leaves it running. Otherwise it
# boots the first available iPhone and shuts that one down when it finishes.
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

# 1. Device slice: link only.
xcrun --sdk iphoneos clang -target "arm64-apple-ios$IOS_DEPLOYMENT_TARGET" "${CFLAGS[@]}" \
  -I "$XCFRAMEWORK/ios-arm64/Headers" "$ROOT/scripts/smoke/smoke.c" \
  "$XCFRAMEWORK/ios-arm64/libcrypto.a" -o "$OUT/smoke-device"
echo "ok   device slice links"

# 2. Simulator slice: link and run.
xcrun --sdk iphonesimulator clang -target "arm64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator" "${CFLAGS[@]}" \
  -I "$XCFRAMEWORK/ios-arm64-simulator/Headers" "$ROOT/scripts/smoke/smoke.c" \
  "$XCFRAMEWORK/ios-arm64-simulator/libcrypto.a" -o "$OUT/smoke-simulator"
codesign --force --sign - "$OUT/smoke-simulator" 2>/dev/null
echo "ok   simulator slice links"

read -r state udid < <(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
ios = [d for runtime, ds in devices.items() if ".SimRuntime.iOS-" in runtime for d in ds]
booted = [d for d in ios if d["state"] == "Booted"]
iphones = [d for d in ios if d["name"].startswith("iPhone")]
pick = (booted or iphones or ios or [None])[0]
print("none -" if pick is None else ("booted " if booted else "shutdown ") + pick["udid"])
')
if [[ "$state" == none ]]; then
  echo "error: no available iOS Simulator device; install an iOS runtime in Xcode." >&2
  exit 1
fi
if [[ "$state" == shutdown ]]; then
  trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true' EXIT
fi
xcrun simctl bootstatus "$udid" -b >/dev/null

set +e
output="$(xcrun simctl spawn "$udid" "$OUT/smoke-simulator" 2>&1)"
status=$?
set -e
echo "$output"
if [[ $status -ne 0 || "$(tail -n 1 <<<"$output")" != "smoke: all checks passed" ]]; then
  echo "error: smoke test failed in the simulator (exit $status)." >&2
  exit 1
fi

# 3. The package as a consumer resolves it.
for destination in 'generic/platform=iOS' 'generic/platform=iOS Simulator'; do
  (cd "$ROOT" && xcodebuild build -quiet \
    -scheme OpenSSLCrypto \
    -destination "$destination" \
    -derivedDataPath "$ROOT/build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO)
  echo "ok   package builds for $destination"
done
