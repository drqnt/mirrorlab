# MirrorLab 0.3.8 — AirPlay FPS / render path

Главная цель версии — убрать локальные пропуски кадров между VideoToolbox и экраном, не меняя уже стабильные AirPlay/FairPlay/session-switching и USB pipeline.

## Что изменилось

- Добавлен отдельный `AirPlayMetalVideoView` только для AirPlay.
- USB по-прежнему использует прежний `MetalVideoView`; рабочий USB renderer не переписывался.
- AirPlay NV12 `CVPixelBuffer` теперь оборачивается через `CVMetalTextureCache` непосредственно в две Metal texture planes (Y + CbCr).
- Убран CoreImage из AirPlay display path: нет CIImage transforms / CIContext render / intermediate processing на каждом кадре.
- Убран `DispatchQueue.main.async + setNeedsDisplay` на каждый AirPlay frame. Он мог coalesce несколько входящих кадров в одну AppKit перерисовку.
- AirPlay MTKView работает от display link до 120 Hz, но GPU submission происходит только при наличии нового frame generation. На 120 Hz ProMotion это уменьшает ожидание следующего presentation slot для 60 fps AirPlay; на 60 Hz дисплеях MetalKit ограничит cadence экраном.
- `framebufferOnly = true` для AirPlay render target.
- YUV→RGB выполняется непосредственно fragment shader'ом с BT.709 matrix; поддерживаются NV12 video-range и full-range.
- CAMetalLayer получает sRGB ColorSync tag без дополнительной CoreImage-конвертации.
- В diagnostics теперь логируется реальный decoded source size / NV12 range при смене формата.
- External Preview публикует свой фактический render FPS в diagnostics.

## Почему не меняли AirPlay negotiation

Receiver уже сообщает клиенту 1920×1080, refreshRate=60 и maxFPS=60. В этой версии оптимизируется именно локальный Mac display path. Разрешение/HEVC/bitrate будут отдельным этапом после измерения 0.3.8 на реальном iPhone/iPad.

## Что проверить

1. Быстрое движение/scrolling на iPhone и iPad.
2. Игру в landscape минимум 20–30 секунд.
3. Main preview и отдельное окно.
4. Сравнить в Live Diagnostics `Получено` и `Показано` — при активном 60 fps контенте они должны стать заметно ближе.
5. Сохранить JSON после теста, желательно пока AirPlay ещё подключён.

Аудио AirPlay в этой версии не добавлялось.
