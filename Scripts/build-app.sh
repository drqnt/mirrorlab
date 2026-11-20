#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"
MANUAL_APP="$PROJECT_ROOT/.build/Manual/MirrorLab.app"
BUILD_LOG="$PROJECT_ROOT/MirrorLab-xcodebuild.log"
ERROR_SUMMARY="$PROJECT_ROOT/MirrorLab-build-errors.txt"
APP_PATH=""

find_xcode_developer_dir() {
    local active_dir=""
    local candidate=""
    local app_path=""

    active_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"

    # Beta comes first deliberately: a release Xcode can be present but unable
    # to run on a beta macOS. Finder normally shows Xcode-beta.app as “Xcode Beta”.
    for candidate in \
        "${MIRRORLAB_DEVELOPER_DIR:-}" \
        "/Applications/Xcode-beta.app/Contents/Developer" \
        "/Applications/Xcode Beta.app/Contents/Developer" \
        "$active_dir" \
        "/Applications/Xcode.app/Contents/Developer"; do
        if [[ -n "$candidate" && -x "$candidate/usr/bin/xcodebuild" ]] && \
            DEVELOPER_DIR="$candidate" /usr/bin/xcodebuild -version >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    # Also find renamed or user-installed copies of Xcode through Spotlight.
    if command -v mdfind >/dev/null 2>&1; then
        while IFS= read -r app_path; do
            candidate="$app_path/Contents/Developer"
            if [[ -x "$candidate/usr/bin/xcodebuild" ]] && \
                DEVELOPER_DIR="$candidate" /usr/bin/xcodebuild -version >/dev/null 2>&1; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null || true)
    fi

    return 1
}

build_with_xcode() {
    local developer_dir="$1"

    mkdir -p "$PROJECT_ROOT/.build"
    printf 'Используется Xcode: %s\n' "${developer_dir%/Contents/Developer}"
    if ! DEVELOPER_DIR="$developer_dir" "$PROJECT_ROOT/Scripts/build-fairplay.sh" \
            2>&1 | /usr/bin/tee "$PROJECT_ROOT/.build/fairplay-build.log"; then
        {
            printf 'MirrorLab: FAIRPLAY PROVIDER BUILD FAILED\n\n'
            /bin/cat "$PROJECT_ROOT/.build/fairplay-build.log" || true
        } > "$ERROR_SUMMARY"
        printf '\nНе удалось собрать embedded FairPlay provider.\n' >&2
        printf 'Пришли файл MirrorLab-build-errors.txt из корня папки проекта.\n' >&2
        return 1
    fi
    if ! DEVELOPER_DIR="$developer_dir" /usr/bin/xcodebuild \
            -project "$PROJECT_ROOT/MirrorLab.xcodeproj" \
            -scheme MirrorLab \
            -configuration Debug \
            -destination "platform=macOS" \
            -derivedDataPath "$DERIVED_DATA" \
            CODE_SIGN_IDENTITY=- \
            CODE_SIGNING_REQUIRED=NO \
            build 2>&1 | /usr/bin/tee "$BUILD_LOG"; then
        {
            printf 'MirrorLab: BUILD FAILED\n\n'
            /usr/bin/grep -n -B 2 -A 3 'error:' "$BUILD_LOG" || true
            printf '\nПолный лог: %s\n' "$BUILD_LOG"
        } > "$ERROR_SUMMARY"
        printf '\nНе удалось скомпилировать MirrorLab. Найденные ошибки:\n' >&2
        /usr/bin/tail -n 160 "$ERROR_SUMMARY" >&2
        printf '\nПришли файл MirrorLab-build-errors.txt из корня папки проекта.\n' >&2
        return 1
    fi

    APP_PATH="$DERIVED_DATA/Build/Products/Debug/MirrorLab.app"
    if [[ ! -x "$APP_PATH/Contents/MacOS/MirrorLab" ]]; then
        printf 'Xcode завершился без готового исполняемого файла MirrorLab.\n' >&2
        printf 'Полный лог: %s\n' "$BUILD_LOG" >&2
        return 1
    fi

    mkdir -p "$APP_PATH/Contents/Frameworks" "$APP_PATH/Contents/Resources"
    /bin/cp "$PROJECT_ROOT/.build/FairPlay/libMirrorFairPlay.dylib" \
        "$APP_PATH/Contents/Frameworks/libMirrorFairPlay.dylib"
    # The checked-in Xcode project predates the new branding/localization files;
    # copy them explicitly so bootstrap builds are correct even before the project
    # is regenerated for the final 1.0 distribution target.
    /bin/cp "$PROJECT_ROOT/MirrorLab/Resources/MirrorLab.icns" \
        "$APP_PATH/Contents/Resources/MirrorLab.icns"
    /usr/bin/ditto "$PROJECT_ROOT/MirrorLab/Resources/ru.lproj" \
        "$APP_PATH/Contents/Resources/ru.lproj"
    /usr/bin/codesign --force --sign - \
        "$APP_PATH/Contents/Frameworks/libMirrorFairPlay.dylib" >/dev/null 2>&1 || true

    printf 'MirrorLab: BUILD SUCCEEDED\nПриложение: %s\n' "$APP_PATH" > "$ERROR_SUMMARY"
    printf '%s\n' "$developer_dir" > "$PROJECT_ROOT/.build/selected-developer-dir"
}

build_with_command_line_tools() {
    local swiftc_path=""
    local sdk_path=""
    local architecture=""
    local target=""
    local source=""
    local -a sources=()

    swiftc_path="$(/usr/bin/xcrun --find swiftc 2>/dev/null || true)"
    sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    if [[ -z "$swiftc_path" || -z "$sdk_path" ]]; then
        printf 'Не найден ни Xcode/Xcode Beta, ни Swift из Command Line Tools.\n' >&2
        printf 'Открой Xcode Beta один раз либо выполни: xcode-select --install\n' >&2
        exit 1
    fi

    architecture="$(uname -m)"
    target="${architecture}-apple-macosx14.0"
    mkdir -p \
        "$MANUAL_APP/Contents/MacOS" \
        "$MANUAL_APP/Contents/Resources"

    while IFS= read -r source; do
        sources+=("$source")
    done < <(find "$PROJECT_ROOT/MirrorLab" -type f -name '*.swift' | sort)

    if ((${#sources[@]} == 0)); then
        printf 'Не найдены Swift-файлы MirrorLab.\n' >&2
        exit 1
    fi

    printf 'Полный Xcode не найден; сборка через Swift из Command Line Tools.\n' >&2
    "$PROJECT_ROOT/Scripts/build-fairplay.sh"
    if ! "$swiftc_path" \
            -parse-as-library \
            -swift-version 5 \
            -O \
            -target "$target" \
            -sdk "$sdk_path" \
            -module-name MirrorLab \
            "${sources[@]}" \
            -framework AppKit \
            -framework AVFoundation \
            -framework Combine \
            -framework CoreImage \
            -framework CoreMedia \
            -framework CoreMediaIO \
            -framework CoreVideo \
            -framework CryptoKit \
            -framework Foundation \
            -framework Metal \
            -framework MetalKit \
            -framework Network \
            -framework Security \
            -framework SwiftUI \
            -framework UniformTypeIdentifiers \
            -framework VideoToolbox \
            -o "$MANUAL_APP/Contents/MacOS/MirrorLab"; then
        printf 'Swift-компилятор не смог собрать MirrorLab.\n' >&2
        return 1
    fi

    /bin/cp "$PROJECT_ROOT/MirrorLab/Info.plist" "$MANUAL_APP/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleExecutable -string MirrorLab "$MANUAL_APP/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleIdentifier -string ua.vovaburiak.MirrorLab "$MANUAL_APP/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleName -string MirrorLab "$MANUAL_APP/Contents/Info.plist"
    /usr/bin/plutil -replace LSMinimumSystemVersion -string 14.0 "$MANUAL_APP/Contents/Info.plist"
    # MirrorLab resources now include FairPlay support files, Russian bundle
    # localization and the full app icon set/ICNS. Copy the resource tree as a
    # whole so the Command Line Tools fallback produces the same branded .app as
    # the normal Xcode build.
    /usr/bin/ditto \
        "$PROJECT_ROOT/MirrorLab/Resources" \
        "$MANUAL_APP/Contents/Resources"
    mkdir -p "$MANUAL_APP/Contents/Frameworks"
    /bin/cp "$PROJECT_ROOT/.build/FairPlay/libMirrorFairPlay.dylib" \
        "$MANUAL_APP/Contents/Frameworks/libMirrorFairPlay.dylib"
    /bin/chmod +x "$MANUAL_APP/Contents/MacOS/MirrorLab"

    APP_PATH="$MANUAL_APP"
}

XCODE_DEVELOPER_DIR="$(find_xcode_developer_dir || true)"
if [[ -n "$XCODE_DEVELOPER_DIR" ]]; then
    build_with_xcode "$XCODE_DEVELOPER_DIR"
else
    build_with_command_line_tools
fi

/usr/bin/codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
printf 'Приложение собрано: %s\n' "$APP_PATH"
/usr/bin/open "$APP_PATH"
