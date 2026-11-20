#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

printf 'MirrorLab 0.3.1 doctor\n'
printf 'macOS: %s\n' "$(sw_vers -productVersion 2>/dev/null || printf 'не определено')"
printf 'Build: %s\n' "$(sw_vers -buildVersion 2>/dev/null || printf 'не определено')"
printf 'Architecture: %s\n' "$(uname -m)"
printf 'Xcode: %s\n' "$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || printf 'не найден')"
printf 'Command Line Tools: %s\n' "$(xcode-select -p 2>/dev/null || printf 'не найдены')"
printf 'Native AirPlay source: %s\n' "$PROJECT_ROOT/MirrorLab/WiFi/AirPlayController.swift"
printf 'USB Screen source: %s\n' "$PROJECT_ROOT/MirrorLab/USB/USBCaptureController.swift"

printf '\nExternal receiver binaries: none\n'
printf 'External runtime package managers: none\n'
printf '\nЕсли что-то не запускается, пришли весь этот вывод вместе с JSON-отчётом приложения.\n'
read -r -p 'Нажми Enter, чтобы закрыть окно…'
