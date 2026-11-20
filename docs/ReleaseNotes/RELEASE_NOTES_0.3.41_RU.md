# MirrorLab 0.3.41

## Цель версии

0.3.41 — pre-virtual-camera polish после пользовательского теста 0.3.40. Media pipeline USB не менялся, а рабочая плавность AirPlay Full HD 60 FPS сохранена. Основные изменения находятся в lifecycle транспорта, Preview UX, USB permissions/multi-device и реальном имени AirPlay receiver.

## Preview / Discord / OBS

- Удалено отдельное overlay-окно с кнопками поверх Preview: оно попадало в window capture и мешало фокусу.
- Preview остаётся отдельным borderless capture-surface без title bar, системной тени и WindowServer chrome.
- Добавлен невидимый `PreviewInteractionView`, который ничего не рисует, но:
  - делает borderless Preview key/main window с первого клика;
  - позволяет двигать окно drag-жестом;
  - возвращает ручной resize за края/углы;
  - сохраняет aspect ratio источника во время resize.
- Fullscreen остаётся доступен через Window menu / горячую клавишу.
- Название `MirrorLab Preview — …` остаётся metadata окна для picker в Discord/OBS, но не рисуется в захватываемой области.

## Lifecycle AirPlay / USB

- Выбранная вкладка теперь действительно владеет транспортом:
  - AirPlay mode полностью останавливает USB capture и USB audio;
  - USB mode полностью останавливает AirPlay listener/services/media.
- Добавлена кнопка `Прекратить трансляцию` в главном UI.
- Для AirPlay она закрывает только текущую sender session и оставляет receiver доступным для нового подключения.
- Для USB она останавливает capture/audio и ставит auto-start на паузу; появляется `Возобновить USB`.

## USB permission UX

- Добавлено отдельное состояние `Требуется доступ`.
- `.authorized` — USB запускается без лишнего запроса.
- `.notDetermined` — macOS показывает системный Camera permission dialog.
- `.denied/.restricted` — MirrorLab больше не молчит и не повторяет бесполезный request; показывает кнопку `Открыть настройки`.
- При возврате в приложение authorization status перепроверяется автоматически.
- Встроенная камера Mac по-прежнему не выбирается: Camera — только системная privacy-category для проводного iOS screen endpoint.

## Несколько USB-устройств

- Удалено постоянное запоминание USB device ID из `UserDefaults`.
- Выбор живёт только пока физический набор подключённых устройств не меняется.
- Один iPhone/iPad — автоматический старт.
- Два и больше — MirrorLab показывает native selection prompt.
- Если подключить/отключить устройство во время активного USB capture, текущая сессия останавливается и выбор пересобирается.
- Live switch доступен через `Window → USB-источник`.

## AirPlay receiver name

- Имя продолжает формироваться автоматически как `MirrorLab — <Computer Name>`.
- Добавлена миграция AirPlay identity: старые development-friendly имена могли кэшироваться iOS/iPadOS по стабильному device/public identifier. При переходе на новую naming-version identity обновляется один раз; далее меняется только при реальном изменении Computer Name.

## Не менялось

- USB device-native compressed path / VideoToolbox decode.
- USB direct CoreAudio PCM path.
- AirPlay FairPlay/AES/parser/VideoToolbox pipeline.
- AirPlay Full HD 60 FPS presentation path из 0.3.40.
