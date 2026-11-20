# MirrorLab 0.3.25 — стабильный display clock + аудио jitter margin

## Что показал тест 0.3.24

Видео до аварии стало визуально почти идеальным. В момент аварии AirPlay и VideoToolbox продолжали принимать/декодировать около 60 кадров/с, очередь оставалась заполненной, но `Показано` падало до 0 FPS. Значит переставал вызываться вынесенный на отдельный RunLoop `CAMetalDisplayLink`, а не умирал AirPlay transport.

Аудио впервые стало практически без секундной задержки, но локальный запас ~22–44 мс оказался слишком мал для burst/jitter и приводил к постоянным подлагиваниям.

## Изменения

### Видео
- `CAMetalDisplayLink` возвращён на стабильный `RunLoop.main` AppKit.
- Сеть, AES, VideoToolbox, AAC→PCM и диагностика остаются на отдельных очередях, поэтому main thread больше не получает прежний per-packet flood.
- External Preview остаётся observer-only и не потребляет общую presentation queue.
- 24 ms NTP scheduler, VideoToolbox и zero-copy NV12→Metal не менялись.

### Аудио
- Direct CoreAudio path сохранён; `AVSampleBufferAudioRenderer` не возвращается.
- Стартовый PCM preroll увеличен примерно до 60 мс.
- Максимальный локальный PCM lead ограничен примерно 120 мс.
- При underrun включается короткий rebuffer: динамик получает тишину до восстановления ~60 мс запаса, вместо серии тресков/микрообрывов.
- `redundantAudio=2` по-прежнему фильтруется до декодера.

Build: 39.
