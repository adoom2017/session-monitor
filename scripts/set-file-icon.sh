#!/bin/bash
# Give a file (the .dmg) the app icon in Finder. The icon lives in the file's extended attributes:
# it shows locally but not after a download, where Finder shows the standard disk image icon.
#
#   scripts/set-file-icon.sh <file>
set -euo pipefail
cd "$(dirname "$0")/.."

file="${1:?usage: set-file-icon.sh <file>}"
osascript -l JavaScript - "$PWD/Resources/AppIcon.icns" "$(cd "$(dirname "$file")" && pwd)/$(basename "$file")" <<'JS' >/dev/null
ObjC.import('AppKit')
function run(argv) {
  const image = $.NSImage.alloc.initWithContentsOfFile(argv[0])
  if (!$.NSWorkspace.sharedWorkspace.setIconForFileOptions(image, argv[1], 0)) throw new Error('cannot set the icon of ' + argv[1])
}
JS
