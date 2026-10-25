#!/bin/bash
# Release build: Developer ID signing, hardened runtime, notarization, stapling, zip + DMG.
#
#   scripts/package-release.sh [options]
#
#   --identity NAME        codesign identity (default: the only "Developer ID Application" in the keychain)
#   --notary-profile NAME  notarytool keychain profile; without it the build is signed but not notarized
#                          (create once: xcrun notarytool store-credentials NAME --apple-id … --team-id …)
#   --version X.Y.Z        CFBundleShortVersionString (default 1.0.0)
#   --build N              CFBundleVersion (default: UTC timestamp yyyymmddHHMM)
#   --bundle-id ID         CFBundleIdentifier (default local.sessionmonitor.app; changing it resets
#                          macOS permissions/preferences, which are keyed by bundle id)
#   --no-dmg               only produce the zip
#
# Output: dist/Codewhistle-<version>.zip and dist/Codewhistle-<version>.dmg
# The local development app in build/ is not touched (its permissions are tied to its signature).
set -euo pipefail
cd "$(dirname "$0")/.."

identity=""
notary_profile=""
version="1.0.0"
build_number="$(date -u +%Y%m%d%H%M)"
bundle_id="local.sessionmonitor.app"
make_dmg=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) identity="$2"; shift 2 ;;
    --notary-profile) notary_profile="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --build) build_number="$2"; shift 2 ;;
    --bundle-id) bundle_id="$2"; shift 2 ;;
    --no-dmg) make_dmg=0; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$identity" ]]; then
  identities="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | sort -u)"
  count="$(printf '%s' "$identities" | grep -c . || true)"
  if [[ "$count" != 1 ]]; then
    echo "error: found $count Developer ID Application identities; pass --identity" >&2
    printf '%s\n' "$identities" >&2
    exit 1
  fi
  identity="$identities"
fi
echo "==> Identity: $identity"

dist="dist"
app="$dist/Codewhistle.app"
zip="$dist/Codewhistle-$version.zip"
dmg="$dist/Codewhistle-$version.dmg"
mkdir -p "$dist"
rm -rf "$app" "$zip" "$dmg"

echo "==> Building and signing ($version, build $build_number)"
SIGN_IDENTITY="$identity" APP_DIR="$app" BUNDLE_ID="$bundle_id" APP_VERSION="$version" \
  APP_BUILD="$build_number" scripts/build-app.sh

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$app"
details="$(codesign -dvv "$app" 2>&1)"
grep -q "flags=.*runtime" <<<"$details" || { echo "error: hardened runtime missing" >&2; exit 1; }
grep -q "^Timestamp=" <<<"$details" || { echo "error: secure timestamp missing" >&2; exit 1; }
grep -q "Authority=Developer ID Application" <<<"$details" || { echo "error: not Developer ID signed" >&2; exit 1; }
codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "automation.apple-events" \
  || { echo "error: apple-events entitlement missing" >&2; exit 1; }
for binary in SessionMonitor sm-hook; do
  [[ "$(lipo -archs "$app/Contents/MacOS/$binary")" == arm64 ]] \
    || { echo "error: $binary is not arm64-only" >&2; exit 1; }
done

notarize() {  # $1 = file to submit
  echo "==> Notarizing $(basename "$1") (this usually takes a few minutes)"
  local result id status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait --output-format json)"
  # plutil reads JSON too; no Python needed.
  id="$(plutil -extract id raw -o - - <<<"$result")"
  status="$(plutil -extract status raw -o - - <<<"$result")"
  echo "    submission $id: $status"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$notary_profile" >&2 || true
    exit 1
  fi
}

if [[ -n "$notary_profile" ]]; then
  ditto -c -k --keepParent "$app" "$dist/notarize-app.zip"
  notarize "$dist/notarize-app.zip"
  rm -f "$dist/notarize-app.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
else
  echo "warning: no --notary-profile; the app is signed but NOT notarized." >&2
  echo "         Other Macs will block it in Gatekeeper. Create a profile once with:" >&2
  echo "         xcrun notarytool store-credentials <name> --apple-id <id> --team-id YH6JCRN97J" >&2
fi

echo "==> Creating $zip"
ditto -c -k --keepParent "$app" "$zip"

if [[ "$make_dmg" == 1 ]]; then
  echo "==> Creating $dmg"
  scripts/make-dmg.sh "$app" "$dmg"
  codesign --force --timestamp --sign "$identity" "$dmg"
  codesign --verify --verbose=2 "$dmg"
  if [[ -n "$notary_profile" ]]; then
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  fi
fi

# Keep LaunchServices from resolving the bundle id to this build output (another copy with the
# same id can make Notification Center show a blank icon).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/$app" 2>/dev/null || true

echo "==> Done"
for artifact in "$zip" "$dmg"; do
  [[ -f "$artifact" ]] && echo "    $(shasum -a 256 "$artifact" | cut -d' ' -f1)  $artifact"
done
echo "    Hooks are installed from the app: Settings → 集成."
