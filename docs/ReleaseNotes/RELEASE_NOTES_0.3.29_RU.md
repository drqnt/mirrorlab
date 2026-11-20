# MirrorLab 0.3.29 — target-scanout pacing + lower audio latency

0.3.29 основана на стабильной 0.3.28. Исправление symmetric 180 ms re-anchor, устранившее длинные зависания, сохранено без изменений.

## Видео

`CVDisplayLink` теперь передаёт в `AirPlayPresentationStore` timestamp ближайшего target output (`inOutputTime.hostTime`), а не `CACurrentMediaTime()` момента входа callback. На тестовом 180 Hz дисплее callback приходит примерно за 7–8 ms до target scanout, поэтому старый выбор по callback-now мог отложить уже подходящий для следующего refresh source frame ещё на один цикл. Renderer, VideoToolbox, Metal, 24 ms target latency и 180 ms symmetric re-anchor не менялись.

Это не маскирует реальные 70–100+ ms сетевые/source stalls: при 24 ms realtime buffer полностью скрыть их без роста latency невозможно. Цель изменения — убрать лишнюю display-phase задержку и часть microhitch от выбора кадра слишком рано.

## Аудио

Direct AAC-ELD → PCM → CoreAudio path сохранён. Локальная политика уменьшена с примерно 60/120 ms до примерно 35/80 ms:

- startup/rebuffer: минимум 35 ms и минимум 3 AAC-ELD packets;
- max local PCM lead: около 80 ms;
- старый двухпакетный (~22 ms) режим не возвращается, потому что он давал выраженные underrun/glitch.

## Не менялось

- FairPlay / AES;
- H.264 parser;
- VideoToolbox decoder;
- transport/thread separation;
- External Preview observer-only;
- 24 ms video target latency;
- symmetric 180 ms timeline re-anchor.
