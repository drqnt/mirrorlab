# MirrorLab 0.3.36

## USB Original — реальный CoreMediaIO stream
- `AVCaptureDevice.formats` у iOS screen-device в 0.3.35 отдавал синтетический 0×0 format без FPS.
- Теперь MirrorLab сопоставляет `AVCaptureDevice.uniqueID` с реальным `CMIODeviceID`.
- Через `kCMIODevicePropertyStreams` получает input streams.
- Через `kCMIOStreamPropertyFormatDescriptions` читает настоящие `CMFormatDescription`.
- Выбирает video format с максимальным encoded pixel resolution и, если DAL stream разрешает запись, задаёт его через `kCMIOStreamPropertyFormatDescription`.
- Отдельно best-effort просит 60 FPS через `kCMIOStreamPropertyFrameRate`.
- Если CMIO driver не разрешает менять format, остаётся прежний AVFoundation fallback.
- Первый реально пришедший `CVPixelBuffer` теперь логируется как `USB actual stream: WIDTH×HEIGHT FOURCC`.
- Report содержит `actual_stream_format`, `cmio_selected_format`, `cmio_available_formats`.

## External Preview lifecycle
- Финальный AirPlay TEARDOWN автоматически закрывает отдельное preview-окно.
- Временный TEARDOWN stream 110 при rotation/reconfiguration окно НЕ закрывает.
- Остановка/обрыв USB capture закрывает USB preview.
- Переключение transport mode закрывает старое external preview, чтобы окно другого backend не оставалось чёрным/stale.
- `stopEverything()` тоже закрывает preview.

## Не менялось
- AirPlay device-aware Original из 0.3.35.
- AirPlay Full HD/720p media pipeline.
- USB low-latency CoreAudio path.
