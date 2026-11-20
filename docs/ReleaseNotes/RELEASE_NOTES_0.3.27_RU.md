# MirrorLab 0.3.27 — один video clock без RunLoop

## Что изменено

- `CAMetalDisplayLink` полностью удалён из AirPlay video path.
- Удалён и custom render-thread `RunLoop`; больше нет зависимости видеопейсинга от Foundation/AppKit RunLoop.
- Единственным clock стал `CVDisplayLink`, который CoreVideo обслуживает на собственном high-priority callback thread.
- В одном callback происходит вся цепочка показа: выбор кадра из сохранённого 0.3.10 timestamp scheduler → `CAMetalLayer.nextDrawable()` → zero-copy NV12 Metal encode → `present`.
- Нет второго presentation clock, burst pacer, watchdog или промежуточного mailbox.
- Сохранён 24 ms `AirPlayPresentationStore` и его NTP cadence/re-anchor логика из 0.3.10.
- External Preview остаётся non-destructive observer: только основной preview двигает общую timestamp queue.
- При перемещении окна на другой экран `CVDisplayLink` переассоциируется с соответствующим display ID.

## Что намеренно не менялось

- FairPlay/AES-CTR, H.264 parser, VideoToolbox, NV12 shaders и parallel transport/decode queues.
- Аудио полностью оставлено как в 0.3.26: AAC-ELD → PCM → CoreAudio, ~60 ms preroll / ~120 ms max local lead. Сначала фиксируем стабильность видео, затем отдельно уменьшаем audio latency.

## Почему

0.3.24 визуально доказала, что off-main video pacing способен давать идеальную плавность, но её RunLoop-вариант позже переставал выдавать кадры. 0.3.25 main-run-loop вариант мог проваливаться с первого кадра, а 0.3.26 исправление lifecycle всё равно не устранило зависание. `CVDisplayLink` убирает сам RunLoop из уравнения: CoreVideo предоставляет собственный display-synchronised high-priority callback thread.
