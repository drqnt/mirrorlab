# MirrorLab 0.3.26 — постоянный render-thread display clock

## Что исправлено

- Видео снова вынесено с AppKit main thread на отдельный `userInteractive` render thread — именно этот вариант в 0.3.24 давал визуально идеальную плавность.
- В отличие от 0.3.24, `RunLoop` больше никогда не управляется с другого потока. `CAMetalDisplayLink` создаётся, регистрируется и инвалидируется только на своём render thread.
- Render thread держится постоянным `CFRunLoopRun()` с собственным input source и останавливается через `CFRunLoopStop`. Это устраняет архитектурную причину, из-за которой callbacks 0.3.24 могли прекратиться через десятки секунд.
- Display link запрашивает фиксированные 60 Hz, соответствующие AirPlay source cadence.
- Presentation scheduler использует `targetPresentationTimestamp` текущего `CAMetalDisplayLink.Update`, то есть выбирает кадр под фактический ожидаемый момент показа.
- Сеть, FairPlay/AES, VideoToolbox, AAC→PCM, CoreAudio и telemetry по-прежнему работают вне main thread.
- External Preview остаётся non-destructive observer и не двигает общую presentation queue.

## Аудио

Аудиопуть 0.3.25 не менялся: AAC-ELD → PCM → CoreAudio, ~60 ms preroll / ~120 ms max local lead. По тесту 0.3.25 звук был чистым и практически без старой секундной задержки, поэтому в этой версии его не трогаем.

## Почему это изменение

В отчёте 0.3.25 было 2656 корректно полученных/декодированных H.264 кадров, но только 161 показанный кадр и 2495 presentation drops. Значит transport/decode продолжали работать, а main-run-loop `CAMetalDisplayLink` не обслуживал 60 Hz presentation. 0.3.24, наоборот, был визуально плавным до остановки неправильно управляемого custom RunLoop. 0.3.26 объединяет эти два наблюдения: off-main display pacing остаётся, но lifecycle RunLoop реализован корректно.
