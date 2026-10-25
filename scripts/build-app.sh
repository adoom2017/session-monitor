#!/bin/bash
# Builds Codewhistle.app (码哨). Defaults: ad-hoc signed into build/ for local development.
# Overrides (used by scripts/package-release.sh):
#   SIGN_IDENTITY  codesign identity ("-" = ad-hoc); a real identity enables hardened runtime + timestamp
#   APP_DIR        output bundle path (default build/Codewhistle.app). Finder shows the localized name
#                  (码哨) only when the file name matches the base CFBundleDisplayName, Codewhistle.
#   BUNDLE_ID      CFBundleIdentifier (default local.sessionmonitor.app; changing it resets
#                  macOS permissions and preferences, which are keyed by bundle id)
#   APP_VERSION    CFBundleShortVersionString (default 1.0.0)
#   APP_BUILD      CFBundleVersion (default 1)
# Apple Silicon only (arm64).
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${SIGN_IDENTITY:--}"
app="${APP_DIR:-build/Codewhistle.app}"
bundle_id="${BUNDLE_ID:-local.sessionmonitor.app}"
version="${APP_VERSION:-1.0.0}"
build_number="${APP_BUILD:-1}"
[[ "$(uname -m)" == arm64 ]] || { echo "error: build on Apple Silicon (arm64 only)" >&2; exit 1; }

swift build -c release -Xswiftc -warnings-as-errors
binary_dir="$(swift build -c release --show-bin-path)"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/SessionMonitor" "$app/Contents/MacOS/SessionMonitor"
cp "$binary_dir/sm-hook" "$app/Contents/MacOS/sm-hook"
# Regenerate with: swift scripts/make-icon.swift Resources
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# The name follows the system language: 码哨 / 碼哨 in Chinese, Codewhistle otherwise.
cp -R Resources/en.lproj Resources/zh-Hans.lproj Resources/zh-Hant.lproj "$app/Contents/Resources/"
# Also a compiled asset catalog (Assets.car + CFBundleIconName): macOS 26 system UI such as
# Notification Center reads the icon from it; the .icns alone showed a blank placeholder there.
icon_work="$(mktemp -d "${TMPDIR:-/tmp}/sm-icon.XXXXXX")"
iconset_dir="$icon_work/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$iconset_dir"
iconutil -c iconset Resources/AppIcon.icns -o "$icon_work/AppIcon.iconset"
cp "$icon_work"/AppIcon.iconset/*.png "$iconset_dir/"
{
  # Contents.json for the mac app icon set (plain shell; no Python needed to build).
  printf '{"images":['
  sep=""
  for size in 16 32 128 256 512; do
    for scale in 1 2; do
      suffix=""; [[ $scale == 2 ]] && suffix="@2x"
      printf '%s{"idiom":"mac","size":"%sx%s","scale":"%sx","filename":"icon_%sx%s%s.png"}' \
        "$sep" "$size" "$size" "$scale" "$size" "$size" "$suffix"
      sep=","
    done
  done
  printf '],"info":{"version":1,"author":"xcode"}}\n'
} > "$iconset_dir/Contents.json"
echo '{"info":{"version":1,"author":"xcode"}}' > "$icon_work/Assets.xcassets/Contents.json"
xcrun actool "$icon_work/Assets.xcassets" --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$icon_work/partial.plist" >/dev/null
rm -rf "$icon_work"
[[ -f "$app/Contents/Resources/Assets.car" ]] || { echo "error: actool produced no Assets.car" >&2; exit 1; }
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundle_id}</string>
<key>CFBundleName</key><string>Codewhistle</string>
<key>CFBundleDisplayName</key><string>Codewhistle</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
<key>LSHasLocalizedDisplayName</key><true/>
<key>CFBundleExecutable</key><string>SessionMonitor</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${build_number}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Codewhistle switches to the Ghostty / iTerm2 tab of the session you click.</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"

if [[ "$identity" == "-" ]]; then
  codesign --force --sign - "$app/Contents/MacOS/sm-hook"
  codesign --force --sign - "$app"
else
  # Inner executable first, then the bundle. Hardened runtime + secure timestamp are required
  # for notarization; the entitlement allows Apple Events (tab switching) under hardened runtime.
  codesign --force --options runtime --timestamp --identifier "${bundle_id}.sm-hook" \
    --sign "$identity" "$app/Contents/MacOS/sm-hook"
  codesign --force --options runtime --timestamp \
    --entitlements Resources/SessionMonitor.entitlements --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"
echo "Built $PWD/$app"
