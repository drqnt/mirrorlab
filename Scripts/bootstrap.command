#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CURRENT_TTY="$(tty 2>/dev/null || true)"

close_own_terminal_tab_after_exit() {
    # Finder-launched .command files normally run in Apple Terminal. Schedule the
    # close after this shell exits so Terminal does not warn about a running job.
    # If bootstrap was launched from another terminal, simply exit normally.
    if [[ "${TERM_PROGRAM:-}" != "Apple_Terminal" || -z "$CURRENT_TTY" || "$CURRENT_TTY" == "not a tty" ]]; then
        return 0
    fi

    (
        sleep 0.6
        /usr/bin/osascript - "$CURRENT_TTY" <<'APPLESCRIPT'
on run argv
    set targetTTY to item 1 of argv
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                try
                    if (tty of t) is targetTTY then
                        if (count of tabs of w) is 1 then
                            close w
                        else
                            close t
                        end if
                        return
                    end if
                end try
            end repeat
        end repeat
    end tell
end run
APPLESCRIPT
    ) >/dev/null 2>&1 &
}

finish_on_error() {
    status=$?
    if ((status != 0)); then
        printf '\nПодготовка остановилась с ошибкой %s.\n' "$status" >&2
        if [[ -f "$PROJECT_ROOT/MirrorLab-build-errors.txt" ]]; then
            printf 'Пришли файл MirrorLab-build-errors.txt из корня папки проекта.\n' >&2
        else
            printf 'Сделай скриншот вывода этого окна.\n' >&2
        fi
        read -r -p 'Нажми Enter, чтобы закрыть окно…' || true
    fi
}
trap finish_on_error EXIT

printf '\nMirrorLab 0.3.50\n\n'

if ! xcode-select -p >/dev/null 2>&1; then
    printf 'Нужны Xcode Command Line Tools. Сейчас macOS покажет окно установки.\n'
    xcode-select --install || true
    printf 'После окончания установки снова запусти этот файл.\n'
    read -r -p 'Нажми Enter, чтобы закрыть окно…'
    exit 1
fi

"$SCRIPT_DIR/build-app.sh"

printf '\nГотово. MirrorLab собран и уже запущен. Окно Terminal закроется автоматически.\n'
trap - EXIT
close_own_terminal_tab_after_exit
exit 0
