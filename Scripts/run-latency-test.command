#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/Tools/Diagnostics/LatencyTest"
PORT=8765

if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 не найден. Он устанавливается вместе с Xcode Command Line Tools.\n' >&2
    read -r -p 'Нажми Enter, чтобы закрыть окно…'
    exit 1
fi

IP_ADDRESS="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [[ -z "$IP_ADDRESS" ]]; then
    IP_ADDRESS="$(ipconfig getifaddr en1 2>/dev/null || true)"
fi

printf 'Тест задержки запущен.\n'
if [[ -n "$IP_ADDRESS" ]]; then
    printf 'Открой на iPhone/iPad: http://%s:%s\n' "$IP_ADDRESS" "$PORT"
else
    printf 'Открой IP-адрес этого Mac на порту %s. Локально: http://127.0.0.1:%s\n' "$PORT" "$PORT"
fi
printf 'Для остановки нажми Control-C.\n\n'

cd "$TEST_DIR"
python3 -m http.server "$PORT" --bind 0.0.0.0
