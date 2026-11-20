# MirrorLab 0.3.9

## AirPlay frame pacing

- Переключили AirPlay-видео с искусственного `0/60, 1/60, 2/60...` PTS на реальные NTP timestamps из mirror packet header.
- Добавили общий timestamp-driven presentation queue для главного и отдельного окна.
- Добавили небольшой jitter buffer с целевой задержкой 80 мс, чтобы TCP/VideoToolbox bursts не превращались в рывки и потерю промежуточных кадров.
- При реальном сетевом провале слишком поздние кадры отбрасываются вместо ускоренного воспроизведения backlog.
- Диагностика `Источник` теперь показывает cadence по AirPlay NTP timestamps, а не локальное количество decode callbacks за секунду.
- В отчёт добавлены source jitter, глубина presentation queue, target latency, lateness и presentation drops.
- Zero-copy NV12 → Metal renderer из 0.3.8 сохранён.
- USB pipeline не изменён.
