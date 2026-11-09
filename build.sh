#!/bin/bash
# Builds TempMonitor.app for Apple Silicon (arm64) and Intel (x86_64).
#
#   ./build.sh                 # both architectures  -> dist/arm64, dist/x86_64
#   ./build.sh arm64           # only Apple Silicon
#   ./build.sh x86_64          # only Intel
#   ./build.sh universal       # both + a combined universal app in dist/universal
#
# Requires the Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="TempMonitor"
MIN_OS="12.0"
SRC="Sources"
RES="Resources"

if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: Xcode Command Line Tools not found. Run: xcode-select --install" >&2
    exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf build                      # old visible intermediates folder (raw executables)
mkdir -p .build
ICON="$RES/AppIcon.icns"
if command -v iconutil >/dev/null 2>&1 && [ -d "$RES/AppIcon.iconset" ]; then
    iconutil -c icns "$RES/AppIcon.iconset" -o .build/AppIcon.icns && ICON=".build/AppIcon.icns"
fi
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

ARCHS=()
UNIVERSAL=0
if [ $# -eq 0 ]; then ARCHS=(arm64 x86_64); fi
for a in "$@"; do
    case "$a" in
        arm64|x86_64) ARCHS+=("$a") ;;
        universal)    ARCHS=(arm64 x86_64); UNIVERSAL=1 ;;
        *) echo "unknown argument: $a" >&2; exit 1 ;;
    esac
done

make_bundle() {   # $1 = output folder name, $2 = binary
    local out="dist/$1"
    local app="$out/$APP.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$2" "$app/Contents/MacOS/$APP"
    cp "$RES/Info.plist" "$app/Contents/Info.plist"
    cp "$ICON" "$app/Contents/Resources/AppIcon.icns"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    codesign --force --sign - --timestamp=none "$app"        # ad-hoc signature (required on arm64)
    touch "$app"                                              # refresh Finder icon cache
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$app" >/dev/null 2>&1 || true
    (cd "$out" && rm -f "../$APP-$1.zip" && ditto -c -k --keepParent "$APP.app" "../$APP-$1.zip")
    echo "  -> $app"
}

build_arch() {
    local arch="$1"
    local target="$arch-apple-macos$MIN_OS"
    local obj=".build/$arch"
    mkdir -p "$obj"
    echo "==> Building $APP for $arch"

    for c in "$SRC"/C/*.c; do
        xcrun clang -target "$target" -isysroot "$SDK" -O2 -Wall \
            -c "$c" -o "$obj/$(basename "${c%.c}").o"
    done

    xcrun swiftc -swift-version 5 -O -parse-as-library \
        -target "$target" -sdk "$SDK" \
        -import-objc-header "$SRC/C/sensors.h" \
        "$SRC"/*.swift "$obj"/*.o \
        -framework IOKit -framework CoreFoundation \
        -framework Metal -framework MetalKit -framework QuartzCore \
        -framework AppKit -framework SwiftUI -framework Combine \
        -o "$obj/$APP"

    make_bundle "$arch" "$obj/$APP"
}

for a in "${ARCHS[@]}"; do build_arch "$a"; done

if [ "$UNIVERSAL" -eq 1 ]; then
    echo "==> Creating universal binary"
    mkdir -p .build/universal
    lipo -create .build/arm64/$APP .build/x86_64/$APP -output .build/universal/$APP
    make_bundle universal .build/universal/$APP
fi

echo "Done. Double-click the .app bundles in ./dist (not the files in .build)."
