#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/Vendor/PlayFair"
OUTPUT_DIR="$PROJECT_ROOT/.build/FairPlay"
OUTPUT="$OUTPUT_DIR/libMirrorFairPlay.dylib"

CLANG="$(/usr/bin/xcrun --find clang)"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

mkdir -p "$OUTPUT_DIR"

SOURCES=(
    "$SOURCE_DIR/MirrorFairPlayBridge.c"
    "$SOURCE_DIR/playfair.c"
    "$SOURCE_DIR/omg_hax.c"
    "$SOURCE_DIR/hand_garble.c"
    "$SOURCE_DIR/modified_md5.c"
    "$SOURCE_DIR/sap_hash.c"
)

printf 'Сборка embedded FairPlay provider (%s)…\n' "$ARCH"
"$CLANG" \
    -dynamiclib \
    -O2 \
    -arch "$ARCH" \
    -isysroot "$SDK" \
    -mmacosx-version-min=14.0 \
    -I "$SOURCE_DIR" \
    "${SOURCES[@]}" \
    -Wl,-install_name,@rpath/libMirrorFairPlay.dylib \
    -Wl,-dead_strip \
    -o "$OUTPUT"

/usr/bin/codesign --force --sign - "$OUTPUT" >/dev/null 2>&1 || true
printf 'FairPlay provider: %s\n' "$OUTPUT"
