# MirrorLab 0.3.24 — параллельный realtime pipeline

База: 0.3.23. Алгоритм видеопоказа 0.3.10 и direct PCM-аудио 0.3.23 сохранены; меняется распределение realtime-работы по потокам/очередям.

## Видео

- `CAMetalDisplayLink` больше не привязан к `RunLoop.main`.
- Каждый AirPlay Metal surface получает отдельный `userInteractive` render RunLoop/thread.
- Metal command encoding идёт с render lane; фактический рендер выполняет GPU.
- Главный preview остаётся единственным владельцем `frameForPresentation`.
- External Preview использует новый non-destructive `frameForObserver` и больше не может вынимать/drop'ать кадры из общей presentation queue.
- Сохранены 24 ms target latency, NTP timeline и VideoToolbox/zero-copy NV12 → Metal путь 0.3.10.

## AirPlay transport / audio

- RTSP + ordered mirror TCP/AES-CTR остаются на отдельной `ControlVideo` queue.
- RTP audio parsing/AES-CBC вынесены на отдельную `AudioTransport` queue.
- AAC-ELD → PCM уже работает на собственной `AirPlayPCM` queue.
- CoreAudio output остаётся realtime callback.
- Audio buffer policy 0.3.23 намеренно не менялся, чтобы отдельно проверить влияние параллелизации.

## Диагностика / UI

- Горячие media counters больше не создают `DispatchQueue.main.async` на каждый audio/video packet.
- Счётчики аккумулируются под короткой блокировкой и публикуются в SwiftUI одним пакетом 4 раза/с.
- Diagnostics snapshot/p95 jitter перенесены на отдельную utility queue и тоже обновляются 4 раза/с.
- Сортировка jitter samples больше не выполняется на каждом видеокадре.

## Зачем

0.3.23 доказала, что H.264 transport/decode может принимать все кадры, а direct PCM устраняет секундную задержку звука, но main-thread contention и два destructive preview renderer'а могли разрушать presentation pacing. 0.3.24 изолирует эти realtime стадии, чтобы macOS могла выполнять независимую CPU-работу параллельно, не блокируя UI/render callback.
