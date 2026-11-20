MirrorLab Beta — standalone Release build
=========================================

1. На Mac с Xcode Beta дважды нажми BUILD_MIRRORLAB_BETA.command.
2. Дождись строки «✅ ГОТОВО».
3. Finder сам откроет папку DIST.
4. Файл DIST/MirrorLab-Beta-macOS-arm64.zip отправляй другому Mac.

Другому Mac НЕ нужны Xcode, Command Line Tools, исходники или Bootstrap.
Эта сборка рассчитана на Apple Silicon (M1/M2/M3/M4/M5) и macOS 14+.

Поскольку приложение пока не notarized через Apple Developer ID, на другом Mac
Gatekeeper может отказать в первом запуске. Если обычное «Всё равно открыть» не
помогает, после перемещения приложения в /Applications достаточно один раз выполнить:

    xattr -dr com.apple.quarantine "/Applications/MirrorLab Beta.app"

После снятия quarantine приложение запускается обычным двойным кликом; Xcode на
компьютере пользователя не требуется.
