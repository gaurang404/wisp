#!/bin/sh
# Builds Wisp into ./build: Wisp.app, Wisp-<version>.dmg and Wisp-<version>.zip.
#
#   ./build.sh                 local build (ad-hoc signed)
#   ./build.sh --install       …and copy to /Applications
#
# Release builds are driven by environment variables (set in CI, or locally):
#   WISP_VERSION     e.g. 1.2.0         (default: latest git tag without "v", else 1.0.0)
#   WISP_BUILD       e.g. 42            (default: git commit count, else 1)
#   SIGN_IDENTITY    "Developer ID Application: Your Name (TEAMID)"  → hardened-runtime signing
#   NOTARY_PROFILE   keychain profile from `xcrun notarytool store-credentials`  → notarize + staple
#     or NOTARY_KEY_ID + NOTARY_ISSUER + NOTARY_KEY_PATH (App Store Connect API key, used in CI)
#   SPARKLE_PRIVATE_KEY_FILE   EdDSA private key (from Sparkle's generate_keys -x)  → signed build/appcast.xml
# The Sparkle public key lives in packaging/sparkle-public-key.txt; without it, in-app updates are disabled.
set -e
cd "$(dirname "$0")"

VERSION=${WISP_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}
VERSION=${VERSION:-1.0.0}
BUILD=${WISP_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
BUNDLE_ID=build.wisp.app
APP=build/Wisp.app
echo "Building Wisp $VERSION ($BUILD)"

# Universal binary: Apple silicon + Intel.
swift build -c release --arch arm64 --arch x86_64
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cp "$BIN_DIR/Wisp" "$APP/Contents/MacOS/Wisp"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Wisp"
strip -x "$APP/Contents/MacOS/Wisp"

# Sparkle (in-app updates). Wisp isn't sandboxed, so Sparkle's XPC services aren't needed (per Sparkle's docs).
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
FW="$APP/Contents/Frameworks/Sparkle.framework"
# Build-time-only parts (headers, module maps) and the sandbox-only XPC services aren't needed at runtime.
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices" \
       "$FW/Versions/B/Headers" "$FW/Headers" "$FW/Versions/B/PrivateHeaders" "$FW/PrivateHeaders" \
       "$FW/Versions/B/Modules" "$FW/Modules"
SPARKLE_PUBLIC_KEY=$(cat packaging/sparkle-public-key.txt 2>/dev/null | tr -d '[:space:]')
lipo -info "$APP/Contents/MacOS/Wisp" | grep -q "x86_64 arm64\|arm64 x86_64" || { echo "not universal"; exit 1; }

ICONSET=build/AppIcon.iconset
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Wisp</string>
  <key>CFBundleDisplayName</key><string>Wisp</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Wisp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Gaurang Sharma. MIT License.</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string><string>x86_64</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>https://wisp.build/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# Signing: Developer ID + hardened runtime for releases, ad-hoc otherwise.
# (Wisp isn't sandboxed and needs no entitlements: network, Keychain and the OAuth loopback all work under hardened runtime.)
# Inside-out: Sparkle's helpers, the framework, then the app.
sign() {
  if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1"
  else
    codesign --force --sign - "$1"
  fi
}
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE_FW/Versions/B/Autoupdate"
sign "$SPARKLE_FW/Versions/B/Updater.app"
sign "$SPARKLE_FW"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [ -z "$SIGN_IDENTITY" ]; then echo "note: ad-hoc signed (set SIGN_IDENTITY for a Developer ID build)"; fi
if [ -z "$SPARKLE_PUBLIC_KEY" ]; then echo "note: no packaging/sparkle-public-key.txt — in-app updates disabled in this build"; fi

# DMG: the app plus an Applications shortcut, for drag-to-install.
DMG=build/Wisp-$VERSION.dmg
STAGE=build/dmg
mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Wisp" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"
rm -rf "$STAGE"
[ -n "$SIGN_IDENTITY" ] && codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

# Notarization (needs a Developer ID–signed build).
notarize() {
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [ -n "$NOTARY_KEY_ID" ]; then
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  else
    return 1
  fi
}
# Stapling fetches Apple's ticket over the network; right after acceptance it can briefly fail (error 65/68).
staple() {
  for attempt in 1 2 3 4 5; do
    xcrun stapler staple "$1" && return 0
    echo "staple attempt $attempt failed for $1, retrying in $((attempt * 15))s…"
    sleep $((attempt * 15))
  done
  return 1
}
if [ -n "$SIGN_IDENTITY" ] && notarize "$DMG"; then
  staple "$DMG"
  staple "$APP"                        # so the zip below carries the ticket too
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "Notarized and stapled"
elif [ -n "$SIGN_IDENTITY" ]; then
  echo "note: signed but not notarized (set NOTARY_PROFILE or NOTARY_KEY_ID/NOTARY_ISSUER/NOTARY_KEY_PATH)"
fi

# ZIP of the (stapled) app — used by Homebrew and in-app updates.
ZIP=build/Wisp-$VERSION.zip
ditto -c -k --keepParent "$APP" "$ZIP"

# Sparkle appcast: one item pointing at this release's zip, EdDSA-signed.
if [ -n "$SPARKLE_PRIVATE_KEY_FILE" ]; then
  SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$ZIP")
  cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Wisp</title>
    <link>https://wisp.build/</link>
    <item>
      <title>Wisp $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/gaurang404/wisp/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/gaurang404/wisp/releases/download/v$VERSION/Wisp-$VERSION.zip" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
  echo "Wrote build/appcast.xml"
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1)), $DMG ($(du -h "$DMG" | cut -f1)), $ZIP ($(du -h "$ZIP" | cut -f1))"

if [ "$1" = "--install" ]; then
  rm -rf /Applications/Wisp.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Wisp.app"
fi
