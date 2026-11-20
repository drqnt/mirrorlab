# MirrorLab 0.3.5

- Исправлен freeze AirPlay после смены ориентации: stream-level TEARDOWN больше не убивает RTSP control session; receiver ждёт новый SETUP.
- TEARDOWN type 110 и type 96 обрабатываются раздельно; финальный session teardown не выключает Bonjour receiver.
- Исправлен overlay AirPlay Waiting поверх уже живого видео: preview теперь напрямую наблюдает AirPlayController.hasLiveVideo.
- При reconfiguration последний кадр сохраняется до нового потока, а VideoToolbox и AES-CTR корректно готовятся заново на следующем video SETUP.
- USB media pipeline не изменён.
