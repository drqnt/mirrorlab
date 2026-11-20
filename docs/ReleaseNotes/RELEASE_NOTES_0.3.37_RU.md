# MirrorLab 0.3.37

## USB Original — device-native output вместо принудительного 420v
- В 0.3.36 `AVCaptureVideoDataOutput` всегда запрашивал `420v`. На muxed iOS screen-device это могло заставлять AVFoundation вставлять conversion/scaling stage до delegate callback.
- 0.3.37 использует документированный `videoSettings = [:]`, то есть просит samples в device-native формате.
- Если device-native sample уже содержит `CVPixelBuffer`, он идёт напрямую в существующий `LatestVideoFrameStore`/Metal path без дополнительного преобразования.
- Если macOS отдаёт native H.264/HEVC `CMSampleBuffer`, новый `USBVideoSampleDecoder` аппаратно декодирует его через VideoToolbox в Metal-compatible NV12 buffer.
- В отчёте `actual_stream_format` теперь явно показывает `native CVPixelBuffer` либо `native compressed`.
- Report также сохраняет `video_output_pixel_formats`, `video_output_codecs` и политику `videoSettings={} (device-native)`.

## Расширенный CoreMediaIO probe
- Помимо `kCMIOStreamPropertyFormatDescriptions` теперь читаются `kCMIOStreamPropertyFormatDescription` и `kCMIOStreamPropertyPreferredFormatDescription`.
- Отдельно инвентаризируются `kCMIOStreamPropertyStillImageFormatDescriptions` — только диагностически, без попытки поставить still-format как video format.
- Читаются current/preferred frame-rate properties.
- Если найден лучший current/preferred/available video format, MirrorLab best-effort пишет его и в active, и в preferred CMIO property и просит 60 FPS через обе rate surfaces.
- Даже если CMIO не публикует/не разрешает эти properties, основной capture всё равно идёт через новый device-native AVCaptureVideoDataOutput path.

## Не менялось
- AirPlay transport, FairPlay/AES, VideoToolbox decode и presentation scheduler.
- AirPlay realtime audio path.
- USB direct PCM → CoreAudio low-latency audio path.
- External Preview lifecycle.
