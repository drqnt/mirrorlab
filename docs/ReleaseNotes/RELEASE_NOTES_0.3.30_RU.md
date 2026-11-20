# MirrorLab 0.3.30

## Что изменено

- Стабильный фикс timeline из 0.3.28 сохранён без изменений: re-anchor остаётся симметричным при отклонении >180 мс.
- CVDisplayLink target-output pacing из 0.3.29 сохранён.
- Video target latency увеличен с 24 до 40 мс. Это примерно один дополнительный 60-FPS кадр и компромисс между минимальной задержкой и сглаживанием реальных burst/gap участков AirPlay TCP.
- Audio startup preroll увеличен примерно с 35 до 45 мс.
- Audio max local lead увеличен с 80 до 100 мс.

## Почему

В отчёте 0.3.29 звук имел 4 163 producer trim/drop events на 13 590 PCM buffers, что совпало с субъективными аудио-подлагиваниями. Видео больше не зависает насовсем, но остаются редкие clustered scheduler drops. 0.3.30 делает только bounded latency tuning, без очередной смены renderer/transport архитектуры.
