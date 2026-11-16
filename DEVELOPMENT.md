# Developing Wisp

Native SwiftUI + URLSession, Swift Package Manager. The only dependency is [Sparkle](https://sparkle-project.org) for in-app updates (fetched automatically by SwiftPM). macOS 14+, Xcode 16+.

## Build & run

```sh
swift run                 # dev build, launches the app
./build.sh                # universal Wisp.app + Wisp-<version>.dmg/.zip in build/ (ad-hoc signed)
./build.sh --install      # …and copy to /Applications
```

## Releasing

Push a tag and GitHub Actions does the rest (`.github/workflows/release.yml`): tests, universal build, Developer ID signing, notarization, and a GitHub Release with `Wisp-<version>.dmg`, `.zip`, stable `Wisp.dmg` / `Wisp.zip` names (used by the website's Download buttons) and `SHA256SUMS.txt`.

```sh
git tag v1.0.0 && git push origin v1.0.0
```

Repository secrets it needs:

| Secret | What |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application certificate + key, exported as .p12, then `base64 -i cert.p12` |
| `DEVELOPER_ID_CERT_PASSWORD` | The .p12 export password |
| `SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_KEY_P8_BASE64` | App Store Connect API key (.p8), `base64 -i AuthKey_XXXX.p8` |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | Issuer ID from App Store Connect → Users and Access → Integrations |
| `SPARKLE_PRIVATE_KEY` | Update-signing key: the contents of the file from `generate_keys -x` (see below) |
| `TAP_TOKEN` | Fine-grained token for `gaurang404/homebrew-tap` only, *Contents: read & write*; expires yearly. Optional — without it the tap isn't bumped |

### Update signing (Sparkle)

Updates are EdDSA-signed. The public key is committed in `packaging/sparkle-public-key.txt`; the private key lives in your login Keychain and in the `SPARKLE_PRIVATE_KEY` secret. Created once with:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys            # prints the public key
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private.key   # export for CI, then delete the file
```

Never lose or change the private key: installed copies only accept updates signed with it. The feed is `https://wisp.build/appcast.xml`, redirected (wisp-site `_redirects`) to the latest release's `appcast.xml`.

Signed release build locally:

```sh
xcrun notarytool store-credentials wisp-notary        # once
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=wisp-notary ./build.sh
```

The release also bumps the Homebrew cask in [gaurang404/homebrew-tap](https://github.com/gaurang404/homebrew-tap) (`brew install --cask gaurang404/tap/wisp`). If that step fails, the release is already published — update `version` and `sha256` (from `SHA256SUMS.txt`) in the tap's `Casks/wisp.rb` by hand.

After a release, update the version shown on the website (`wisp-site/index.html`, `fineprint`). If the DMG size changed by more than 0.5 MB, update the site's download figure (stats strip) and `BENCHMARKS.md` — the size is quoted only in those two places.

## Tests

```sh
swift test
```

Network-dependent tests (OAuth loopback, live spec discovery, GraphQL demo API) skip themselves when offline.

## Benchmarks

A plain release build reads your real `state.json` and production Keychain item. For launch and memory runs, swap in a release-optimised binary built with `-DDEBUG` so `WISP_DATA_DIR` isolates both (the debug hooks are inert without their env vars; the binary is ~3% larger):

```sh
./build.sh && swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DDEBUG
cp "$(swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DDEBUG --show-bin-path)/Wisp" build/Wisp.app/Contents/MacOS/Wisp
install_name_tool -add_rpath @executable_path/../Frameworks build/Wisp.app/Contents/MacOS/Wisp && strip -x build/Wisp.app/Contents/MacOS/Wisp
codesign --force --deep -s - build/Wisp.app
```

```sh
WISP_DATA_DIR=$(mktemp -d) swift scripts/bench-launch.swift build/Wisp.app/Contents/MacOS/Wisp 6   # launch time, memory, idle CPU
WISP_BENCH=1 swift test -c release --filter BenchTests                     # JSON, parsers, import
# request overhead: serve JSON locally (python3 -m http.server 8765), then
WISP_BENCH=1 WISP_BENCH_URL=http://127.0.0.1:8765/big.json swift test -c release --filter BenchTests/testRequestLatency
```

## Screenshots

README images live in `docs/images/`. Debug builds include a snapshot hook (`Sources/Wisp/DebugSnapshot.swift`) that drives the app and writes the window to a PNG; `scripts/frame-screenshot.swift` adds the rounded window, shadow and background:

```sh
BIN=$(swift build --show-bin-path)/Wisp
WISP_WINDOW=1440x900 WISP_DEMO_OPEN="List users" WISP_SNAPSHOT=/tmp/hero.png WISP_SNAPSHOT_DELAY=4 "$BIN"
swift scripts/frame-screenshot.swift /tmp/hero.png - docs/images/hero-dark.jpg
```

Debug runs with `WISP_DATA_DIR=<dir>` keep state there and use a separate Keychain item (service `build.wisp.app.debug`, account = that dir; remove with `security delete-generic-password -s build.wisp.app.debug -a <dir>`), so snapshots never touch your real data — use it for any scene that saves. A debug binary needs `DYLD_FRAMEWORK_PATH=$(swift build --show-bin-path)` to find Sparkle. Named keys scene (environment editor with two keys): `WISP_DARK=1 WISP_WINDOW=1050x640 WISP_DEMO_KEYS_URL=https://gaurang404.github.io/wisp-demo/api/v1/account.json WISP_DEMO_URL3=<same URL> WISP_DEMO_SHEET=env`. Don't launch the debug binary through `timeout`, `env -i` or other SIP-protected tools that strip `DYLD_*`. `WISP_DARK` / `WISP_LIGHT` force the appearance.

Sheets (Query Builder, Code, Environments) are written next to the window capture as `*-sheet.png`; pass that as the second argument to composite it. Any screenshot can also be replaced with a CleanShot capture of the same scene.

## Where things are

| | |
|---|---|
| `Store.swift` | App state, sending, environments, persistence, Keychain |
| `HTTPClient.swift` | Building and sending requests, redirects |
| `Smarts.swift` | Credential extraction, next-page finder, 401 hints |
| `Importer.swift`, `YAML.swift`, `SpecDiscovery.swift` | Imports and docs-page spec discovery |
| `GraphQL*.swift` | Schema introspection, query builder |
| `OAuth.swift`, `Secrets.swift` | OAuth 2 flows, Keychain storage |
| `DesignSystem.swift` | Shared look: surfaces, tabs, chips, accent colour |
