# MirrorLab 0.3.38

## USB privacy hardening

- Удалён fallback, который при отсутствии явно распознанного iPhone/iPad мог выбрать первый внешний muxed AVCaptureDevice.
- Теперь список USB источников содержит только подтверждённые iPhone/iPad screen endpoints; перед стартом действует повторный guard.
- Это гарантирует, что MirrorLab не выбирает встроенную камеру Mac и не подменяет iPad случайным внешним capture-device.
- Текст Camera permission и UI уточнён: macOS классифицирует проводной screen stream iPhone/iPad как Camera capture, поэтому системный зелёный индикатор остаётся ожидаемым поведением ОС.
- USB video/audio pipeline не изменён: device-native H.264/HEVC → VideoToolbox → Metal, PCM 48 kHz → direct CoreAudio.

## Разрешение

Отчёт 0.3.37 подтвердил, что при `videoSettings = [:]` iPad13,4 отдаёт device-native compressed H.264 1718×1200. Следовательно, downscale происходит до MirrorLab, внутри Apple USB screen service; принудительный 420v больше не является кандидатом root cause.
