# MirrorLab 0.3.28 — исправление forward PTS discontinuity

0.3.28 основана на 0.3.27 и меняет только политику re-anchor в `AirPlayPresentationStore`.

DIAG1 доказал конкретный failure mode: AirPlay source PTS иногда прыгает вперёд на сотни миллисекунд, хотя соседние H.264 access units приходят через несколько миллисекунд. Старый scheduler сбрасывал timeline, когда она отставала от arrival более чем на 180 ms, но разрешал ей уйти вперёд вплоть до 1 секунды. При bounded queue из 10 кадров это создавало ловушку: будущие кадры переполняли очередь и удалялись ещё до своего presentation time, поэтому display link продолжал работать, но бесконечно повторял старый кадр.

В 0.3.28 reset стал симметричным: если рассчитанная timeline отличается от live arrival более чем на существующий `timelineResetThreshold = 180 ms` в любую сторону, anchor немедленно переносится на свежий кадр (`arrival + 24 ms`).

Не изменялись:

- CVDisplayLink / Metal renderer;
- VideoToolbox decoder;
- FairPlay / AES;
- H.264 parser;
- 24 ms normal target latency;
- late-frame catch-up policy;
- External Preview observer semantics;
- AAC-ELD → PCM → CoreAudio path и его 60/120 ms audio policy.

Цель версии — устранить именно длительные freezes/presentation-overflow после forward PTS jumps, не меняя нормальный steady-state pacing.
