#!/bin/bash
# Publishes the built apps as a GitHub release.
#   bash release.sh            -> release v1.0
#   bash release.sh 1.1        -> release v1.1 (run ./build.sh first)
# Needs the GitHub CLI: brew install gh && gh auth login
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0}"
REPO="lydianb79/TempMonitor"
OUT="dist/release"

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh && gh auth login" >&2; exit 1; }

mkdir -p "$OUT"
ARM="$OUT/TempMonitor-$VERSION-AppleSilicon-arm64.zip"
X86="$OUT/TempMonitor-$VERSION-Intel-x86_64.zip"
[ -f "$ARM" ] || cp dist/TempMonitor-arm64.zip "$ARM"
[ -f "$X86" ] || cp dist/TempMonitor-x86_64.zip "$X86"

NOTES="$OUT/notes-$VERSION.md"
if [ ! -f "$NOTES" ]; then
    cat > "$NOTES" <<EOF
Native macOS app (SwiftUI + Metal) that shows and monitors CPU and GPU temperatures.

| Your Mac | File |
|---|---|
| Apple Silicon (M1–M4) | \`$(basename "$ARM")\` |
| Intel | \`$(basename "$X86")\` |

Unzip it and drag **TempMonitor.app** to Applications (macOS 12 or later). The app is ad-hoc signed, not notarized,
so the first time you open it, right-click it and choose **Open**, or run \`xattr -dr com.apple.quarantine /Applications/TempMonitor.app\`.

### Features
- Live CPU and GPU ring gauges, session min/max, a sparkline and a per-sensor grid
- Animated Metal fire background and a menu bar readout
- History recording with CSV export (⌘S) and graph export as PNG (⇧⌘S) or PDF
- Optional auto-save of the CSV and graph when quitting

### SHA-256
\`\`\`
$(cd "$OUT" && shasum -a 256 "$(basename "$ARM")" "$(basename "$X86")")
\`\`\`
EOF
fi

gh release create "v$VERSION" "$ARM" "$X86" \
    --repo "$REPO" --target main \
    --title "TempMonitor $VERSION" --notes-file "$NOTES"
