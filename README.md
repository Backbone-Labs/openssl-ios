# openssl-ios

OpenSSL's `libcrypto`, built as a static XCFramework for iOS and distributed as a
Swift package. It is built from upstream source checked against a pinned SHA-256,
on the OpenSSL 3.5 LTS line.

| | |
|---|---|
| OpenSSL | 3.5.7 (`scripts/openssl-source.env`) |
| Slices | `ios-arm64` (device), `ios-arm64-simulator` |
| Deployment target | iOS 17.0 |
| Linkage | static `libcrypto.a`, no `libssl` |
| License | Apache-2.0 (OpenSSL's, which also covers this repo's scripts) |

## Using it

```swift
dependencies: [
    .package(url: "https://github.com/Backbone-Labs/openssl-ios.git", exact: "3.5.700"),
],
targets: [
    .target(
        name: "MyCTarget",
        dependencies: [.product(name: "OpenSSLCrypto", package: "openssl-ios")]
    ),
]
```

```c
#include <openssl/evp.h>
```

- **Pin `exact:`.** This is a prebuilt crypto binary, so upgrades should be
  deliberate.
- **Include headers textually.** There is no module map, so `import OpenSSLCrypto`
  from Swift does not work; call it from a C target.
- **The repo is public on purpose.** SwiftPM downloads the release asset without
  credentials, which a private repo's release would not allow.

## Versions

Tags are `v<major>.<minor>.<patch × 100 + rebuild>`:

| Tag | Contents |
|---|---|
| `v3.5.700` | OpenSSL 3.5.7, first build |
| `v3.5.701` | the same source rebuilt (new Xcode, signing change, script fix) |
| `v3.5.900` | OpenSSL 3.5.9 |

SwiftPM ignores `+build` metadata when it orders versions, so `3.5.7+1` would sort
equal to `3.5.7+2`. That is why the rebuild counter lives in the patch number.

## How main and tags differ

`Package.swift` has two constants, `releaseVersion` and `releaseChecksum`:

- **On main they are empty.** The binary target is then the local
  `build/OpenSSLCrypto.xcframework`, and the binary is never committed.
- **On a release commit** `scripts/stamp-release.sh` fills them in. That points the
  target at the GitHub Release asset.

The release commit is reachable only from its tag, so main never changes during
a release. Depend on tags; `branch: "main"` will not resolve without a local build.

## Building locally

```sh
scripts/build-xcframework.sh   # downloads + verifies the source, builds both slices
scripts/smoke-test.sh          # links both slices, runs test vectors in a simulator,
                               # builds the package for both platforms
```

The build writes `build/BUILD_INFO.txt` with the toolchain, Configure options and
the SHA-256 of each `libcrypto.a`. The same source and the same Xcode produce a
byte-identical unsigned xcframework, wherever it is built. That is how to check
a published release: rebuild with the Xcode its notes name and compare the
`libcrypto.a` hashes. The zip's checksum will not match, because signing adds a
timestamp.

To try an unreleased build in a consuming app, point the app at this checkout
as a local package (Xcode: File > Add Package Dependencies > Add Local).

## Releasing

Run the **Release** workflow (`gh workflow run release.yml -f rebuild=0`). It:

1. builds and smoke-tests,
2. signs,
3. zips and computes the checksum,
4. stamps `Package.swift` in a release commit,
5. tags it and publishes the GitHub Release with the zip and build notes.

The header of `.github/workflows/release.yml` lists the signing secrets.

**Use an Xcode no newer than the one consuming apps build with.** Objects from a
newer compiler can fail to link with an older one. Set the repo variable
`XCODE_VERSION` (for example `26.3`) to pin the runner's Xcode.

## Bumping OpenSSL

1. Update `OPENSSL_VERSION` and `OPENSSL_SHA256` in `scripts/openssl-source.env`.
   Take the digest from the upstream release, not from your own download:
   ```sh
   gh api repos/openssl/openssl/releases/tags/openssl-3.5.9 \
     --jq '.assets[] | select(.name|endswith(".tar.gz")) | .digest'
   ```
2. Open a PR. CI builds and smoke-tests it.
3. After merging, run Release with `rebuild=0`.

Stay on an LTS line (3.5 until April 2030) unless there is a reason to move.

## Things that look optional but are not

- **No `module.modulemap` in the headers.** Xcode copies every static
  xcframework's `Headers/` into one shared `Build/Products/<config>/include/`.
  A module map there collides with any other xcframework that ships one
  ("Multiple commands produce .../include/module.modulemap"). The build script
  fails if one appears.
- **Signing.** Apple lists OpenSSL among the SDKs that need a privacy manifest,
  and also a signature when shipped as a binary
  (<https://developer.apple.com/support/third-party-SDK-requirements/>).
  Releases are signed unless the workflow is told otherwise.
- **Privacy manifest.** A static-library binary target cannot carry resources.
  The empty `OpenSSLCryptoPrivacy` target therefore exists to put
  `PrivacyInfo.xcprivacy` into the app.
  - libcrypto calls `stat`/`fstat`, in its X509 directory lookup, config
    loading, `RAND_load_file` and the file store. That puts it in the
    file-timestamp category.
  - The declared reason is `0A2A.1`: the SDK reaches those calls only when the
    app calls its file APIs.
  - Recheck the reason when bumping OpenSSL:
    ```sh
    nm -u build/OpenSSLCrypto.xcframework/ios-arm64/libcrypto.a | sort -u
    ```
- **License.** `LICENSE` is OpenSSL's Apache-2.0 text, verbatim. Keeping it at the
  repo root is what lets license scanners (LicensePlist) attribute OpenSSL
  correctly in consuming apps.
