#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DERIVED="$ROOT/.build/ReleaseDerivedData"
DIST="$ROOT/DIST"
APP_SRC="$DERIVED/Build/Products/Release/MirrorLab.app"
APP="$DIST/MirrorLab Beta.app"
ZIP="$DIST/MirrorLab-Beta-macOS-arm64.zip"
LOG="$DIST/MirrorLab-Beta-build.log"

mkdir -p "$DIST"
rm -rf "$DERIVED" "$APP" "$ZIP"
: > "$LOG"

pause_on_error() {
    code=$?
    if (( code != 0 )); then
        printf '\n❌ Сборка остановилась с ошибкой %s.\nЛог: %s\n' "$code" "$LOG" >&2
        read -r -p 'Нажми Enter, чтобы закрыть окно…' || true
    fi
}
trap pause_on_error EXIT

find_xcode() {
    local active=""
    active="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    for dev in \
        "${MIRRORLAB_DEVELOPER_DIR:-}" \
        "/Applications/Xcode-beta.app/Contents/Developer" \
        "/Applications/Xcode Beta.app/Contents/Developer" \
        "$active" \
        "/Applications/Xcode.app/Contents/Developer"; do
        if [[ -n "$dev" && -x "$dev/usr/bin/xcodebuild" ]] && \
           DEVELOPER_DIR="$dev" /usr/bin/xcodebuild -version >/dev/null 2>&1; then
            printf '%s\n' "$dev"
            return 0
        fi
    done
    return 1
}

DEV="$(find_xcode || true)"
if [[ -z "$DEV" ]]; then
    echo '❌ Не найден полноценный Xcode / Xcode Beta.'
    echo 'Эту Release-сборку нужно сделать на твоём Mac с Xcode Beta.'
    exit 1
fi

{
    echo 'MirrorLab Beta standalone Release builder'
    echo "Project: $ROOT"
    echo "Xcode: ${DEV%/Contents/Developer}"
    DEVELOPER_DIR="$DEV" /usr/bin/xcodebuild -version
    echo
    echo '1/5 — FairPlay arm64…'
} | /usr/bin/tee -a "$LOG"

DEVELOPER_DIR="$DEV" "$ROOT/Scripts/build-fairplay.sh" 2>&1 | /usr/bin/tee -a "$LOG"

printf '\n2/5 — MirrorLab Release arm64…\n' | /usr/bin/tee -a "$LOG"
DEVELOPER_DIR="$DEV" /usr/bin/xcodebuild \
    -project "$ROOT/MirrorLab.xcodeproj" \
    -scheme MirrorLab \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    ENABLE_DEBUG_DYLIB=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build 2>&1 | /usr/bin/tee -a "$LOG"

if [[ ! -x "$APP_SRC/Contents/MacOS/MirrorLab" ]]; then
    echo "❌ Xcode не создал $APP_SRC" | /usr/bin/tee -a "$LOG"
    exit 1
fi

printf '\n3/5 — Упаковка standalone bundle…\n' | /usr/bin/tee -a "$LOG"
/usr/bin/ditto "$APP_SRC" "$APP"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources"
/bin/cp "$ROOT/.build/FairPlay/libMirrorFairPlay.dylib" \
    "$APP/Contents/Frameworks/libMirrorFairPlay.dylib"
/bin/cp "$ROOT/MirrorLab/Resources/MirrorLab.icns" \
    "$APP/Contents/Resources/MirrorLab.icns"
/usr/bin/ditto "$ROOT/MirrorLab/Resources/ru.lproj" \
    "$APP/Contents/Resources/ru.lproj"

# The executable remains MirrorLab; only the user-visible beta label changes.
/usr/bin/plutil -replace CFBundleDisplayName -string 'MirrorLab Beta' "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string 'MirrorLab Beta' "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIconFile -string 'MirrorLab.icns' "$APP/Contents/Info.plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string '14.0' "$APP/Contents/Info.plist"
/usr/bin/plutil -insert MirrorLabReleaseChannel -string 'Beta' "$APP/Contents/Info.plist" 2>/dev/null || \
    /usr/bin/plutil -replace MirrorLabReleaseChannel -string 'Beta' "$APP/Contents/Info.plist"

# A real Release product must not carry Xcode's debug trampoline dylibs.
/bin/rm -f \
    "$APP/Contents/MacOS/MirrorLab.debug.dylib" \
    "$APP/Contents/MacOS/__preview.dylib"

# Strip quarantine/resource xattrs from the locally generated bundle before signing.
/usr/bin/xattr -cr "$APP" 2>/dev/null || true

printf '\n4/5 — Ad-hoc подпись и проверка…\n' | /usr/bin/tee -a "$LOG"
/usr/bin/codesign --force --sign - --timestamp=none \
    "$APP/Contents/Frameworks/libMirrorFairPlay.dylib" 2>&1 | /usr/bin/tee -a "$LOG"
/usr/bin/codesign --force --sign - --timestamp=none \
    "$APP" 2>&1 | /usr/bin/tee -a "$LOG"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | /usr/bin/tee -a "$LOG"

MAIN_ARCH="$(/usr/bin/file "$APP/Contents/MacOS/MirrorLab")"
FP_ARCH="$(/usr/bin/file "$APP/Contents/Frameworks/libMirrorFairPlay.dylib")"
echo "$MAIN_ARCH" | /usr/bin/tee -a "$LOG"
echo "$FP_ARCH" | /usr/bin/tee -a "$LOG"

if ! echo "$MAIN_ARCH" | /usr/bin/grep -q 'arm64'; then
    echo '❌ Основной бинарник не arm64.' | /usr/bin/tee -a "$LOG"
    exit 1
fi
if ! echo "$FP_ARCH" | /usr/bin/grep -q 'arm64'; then
    echo '❌ FairPlay dylib не arm64.' | /usr/bin/tee -a "$LOG"
    exit 1
fi
if [[ -e "$APP/Contents/MacOS/MirrorLab.debug.dylib" || -e "$APP/Contents/MacOS/__preview.dylib" ]]; then
    echo '❌ В Release осталась Debug-обвязка Xcode.' | /usr/bin/tee -a "$LOG"
    exit 1
fi

# Fail only if an *actual dependency entry* is linked directly to a user path.
# `otool -L` prints the inspected binary path on line 1 (for example
# `/Users/volodymyr/.../MirrorLab:`), so checking the complete output gives a false
# positive on every locally built app. Skip that header and inspect dependency rows.
RUNTIME_DEPS="$(/usr/bin/otool -L "$APP/Contents/MacOS/MirrorLab" | /usr/bin/tail -n +2)"
if printf '%s\n' "$RUNTIME_DEPS" | /usr/bin/grep -qE '^[[:space:]]*/Users/'; then
    echo '❌ Найдена абсолютная /Users/... runtime-зависимость.' | /usr/bin/tee -a "$LOG"
    printf '%s\n' "$RUNTIME_DEPS" | /usr/bin/tee -a "$LOG"
    exit 1
fi

# Log the real dependency list for easy verification on another Mac.
printf '\nRuntime dependencies (verified):\n%s\n' "$RUNTIME_DEPS" | /usr/bin/tee -a "$LOG"

printf '\n5/5 — ZIP для другого Mac…\n' | /usr/bin/tee -a "$LOG"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

HASH="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')"
printf '\n✅ ГОТОВО\n\nПриложение: %s\nАрхив для друга: %s\nSHA-256: %s\n\n' \
    "$APP" "$ZIP" "$HASH" | /usr/bin/tee -a "$LOG"

echo 'Другу отправляй именно MirrorLab-Beta-macOS-arm64.zip.' | /usr/bin/tee -a "$LOG"
echo 'Xcode на его Mac не нужен.' | /usr/bin/tee -a "$LOG"

trap - EXIT
/usr/bin/open "$DIST"
