#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

required=(
    "MirrorLab.xcodeproj/project.pbxproj"
    "MirrorLab/Info.plist"
    "MirrorLab/MirrorLabApp.swift"
    "MirrorLab/ContentView.swift"
    "MirrorLab/WiFi/AirPlayController.swift"
    "MirrorLab/WiFi/EmbeddedFairPlayProvider.swift"
    "Vendor/PlayFair/MirrorFairPlayBridge.c"
    "Vendor/PlayFair/playfair.c"
    "Vendor/PlayFair/omg_hax.h"
    "Scripts/build-fairplay.sh"
    "MirrorLab/WiFi/AirPlayVideoDecoder.swift"
    "MirrorLab/WiFi/AirPlayMetalVideoView.swift"
    "MirrorLab/USB/USBCaptureController.swift"
)

for path in "${required[@]}"; do
    if [[ ! -f "$PROJECT_ROOT/$path" ]]; then
        printf 'Нет обязательного файла: %s\n' "$path" >&2
        exit 1
    fi
done

if [[ -e "$PROJECT_ROOT/Vendor/UxPlay" || -e "$PROJECT_ROOT/Scripts/build-uxplay.sh" ]]; then
    printf 'В проекте остался UxPlay — native rewrite неполный.\n' >&2
    exit 1
fi

if grep -R -n -E 'UxPlayController|Resources/Binaries/uxplay|Vendor/UxPlay|build-uxplay' \
    "$PROJECT_ROOT/MirrorLab" "$PROJECT_ROOT/MirrorLab.xcodeproj" \
    "$PROJECT_ROOT/Scripts/build-app.sh" "$PROJECT_ROOT/project.yml" >/dev/null 2>&1; then
    printf 'В runtime/build-файлах осталась старая receiver-зависимость.\n' >&2
    exit 1
fi

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PROJECT_ROOT/MirrorLab/Info.plist"
fi

for script in "$PROJECT_ROOT"/Scripts/*.sh "$PROJECT_ROOT"/Scripts/*.command; do
    bash -n "$script"
done

printf 'Структура MirrorLab %s прошла локальную проверку.\n' "$(cat "$PROJECT_ROOT/VERSION")"
