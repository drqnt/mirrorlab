# MirrorLab 0.3.3

Главная цель версии — впервые замкнуть реальный AirPlay video crypto pipeline после успешного transport/framing теста 0.3.2.

- Встроен PlayFair как **source-level компонент**, а не внешний receiver/process.
- PlayFair собирается локально в `libMirrorFairPlay.dylib` и загружается внутри процесса MirrorLab.
- Реализован `ekey` unwrap: 164-байтный FPLY key message + 72-байтный `ekey` → 16-байтный AES session key.
- Реализован вывод video key/IV по `streamConnectionID` через SHA-512 `AirPlayStreamKey…` / `AirPlayStreamIV…`.
- Реализован непрерывный AES-128-CTR decrypt mirror payload через CommonCrypto.
- Расшифрованные AVCC H.264 packets отправляются в VideoToolbox; decoded `CVPixelBuffer` идёт в существующий Metal renderer.
- Добавлены отдельные диагностические счётчики decrypt/VideoToolbox, чтобы следующий real-device тест сразу показал, на каком слое остановился pipeline.
- `POST /feedback` остаётся heartbeat и больше не засоряет Events.
- USB media pipeline не изменялся.
- Полный GPLv3 source + provenance включены в архив.
- Crypto path проверен на реальном 0.3.2 capture: после unwrap + SHA-512 derivation + AES-CTR первый encrypted video payload превращается в корректный AVCC access unit с IDR NAL; это не только статическая заготовка.
- AES-CTR state защищён от повторного `SETUP type=110`: повторная negotiation не перематывает CTR обратно к IV.
- VideoToolbox session помечена как realtime для минимизации buffering/latency.
