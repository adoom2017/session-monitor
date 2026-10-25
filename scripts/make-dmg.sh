#!/bin/bash
# Build a drag-to-install DMG: a 640×400 window with 128pt icons, the app on the left, an
# Applications link on the right and a background with an arrow and a hint
# (scripts/make-dmg-background.swift). Does not sign; package-release.sh signs and notarizes it.
#
#   scripts/make-dmg.sh <Codewhistle.app> <output.dmg>
#
# The layout is written by Finder (AppleScript) into the volume's .DS_Store, so the first run asks
# to let the terminal control Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: make-dmg.sh <app> <output.dmg>}"
dmg="${2:?usage: make-dmg.sh <app> <output.dmg>}"
volname="Codewhistle"
app_name="$(basename "$app")"

work="$(mktemp -d "${TMPDIR:-/tmp}/sm-dmg.XXXXXX")"
device=""
cleanup() {
  [[ -n "$device" ]] && hdiutil detach -quiet "$device" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

staging="$work/staging"
mkdir -p "$staging/.background"
ditto "$app" "$staging/$app_name"
ln -s /Applications "$staging/Applications"
swift scripts/make-dmg-background.swift "$work/bg.png" 1
swift scripts/make-dmg-background.swift "$work/bg@2x.png" 2
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$staging/.background/background.tiff" >/dev/null 2>&1

# Lay out a writable image, then compress it.
rw="$work/rw.dmg"
hdiutil create -quiet -volname "$volname" -srcfolder "$staging" -fs HFS+ -format UDRW -ov "$rw"
# A stale volume with the same name would make Finder lay out the wrong window.
[[ -d "/Volumes/$volname" ]] && hdiutil detach -quiet "/Volumes/$volname" 2>/dev/null || true
device="$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | awk '/Apple_HFS/ {print $1; exit}')"
mount="/Volumes/$volname"
[[ -d "$mount" ]] || { echo "error: $mount not mounted" >&2; exit 1; }

# Window bounds include the 28pt title bar; icon positions are icon centers in the content area
# and must match make-dmg-background.swift.
osascript <<OSA
tell application "Finder"
  tell disk "$volname"
    open
    set win to container window
    set current view of win to icon view
    set toolbar visible of win to false
    set statusbar visible of win to false
    set pathbar visible of win to false
    set bounds of win to {200, 120, 840, 548}
    set opts to icon view options of win
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$app_name" of win to {170, 190}
    set position of item "Applications" of win to {470, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

# Finder writes .DS_Store asynchronously; wait for it before detaching.
for _ in {1..20}; do [[ -f "$mount/.DS_Store" ]] && break; sleep 0.5; done
[[ -f "$mount/.DS_Store" ]] || { echo "error: Finder did not save the window layout" >&2; exit 1; }
chmod -Rf go-w "$mount" 2>/dev/null || true
sync
hdiutil detach -quiet "$device"
device=""

rm -f "$dmg"
hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
echo "    $dmg"
