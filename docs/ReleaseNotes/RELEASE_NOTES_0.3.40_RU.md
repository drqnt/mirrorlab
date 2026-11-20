# MirrorLab 0.3.40

## AirPlay: восстановление layer-owned display pacing

Последний отчёт 0.3.39 снова показал характерное расхождение: источник/VideoToolbox держат около 60 FPS, а primary preview коммитит заметно меньше новых source frames. Поэтому 0.3.40 не меняет FairPlay, AES, parser, VideoToolbox или AirPlay audio; изменён именно последний display/present участок.

- Generic `CVDisplayLink → nextDrawable()` path заменён на layer-owned `CAMetalDisplayLink`.
- Это сознательный возврат к display path из 0.3.10 — исторического golden reference по субъективной плавности.
- `CAMetalDisplayLink` сам выдаёт drawable для конкретного `CAMetalLayer` update, поэтому source-frame selection больше не живёт отдельно от drawable acquisition.
- Запрошен диапазон 60–120 Hz, preferred 120 Hz и `preferredFrameLatency = 1`.
- Сохранены zero-copy NV12 → Metal, bounded timestamp queue, 40 ms realtime margin, symmetric 180 ms re-anchor и discard старого backlog вместо slow-motion playback.
- `presentationDroppedFrames` теперь сбрасывается на границе новой AirPlay-сессии; format/orientation reset внутри одной сессии историю не обнуляет.

## Preview: чистое окно для Discord/OBS

- Preview теперь создаётся как `borderless + resizable` capture surface без системной title bar.
- У окна отключена системная тень; видеохолст остаётся прямоугольным и не наследует стандартные округлённые углы macOS chrome.
- `NSWindow.title` сохраняется как metadata (`MirrorLab Preview — …`), поэтому окно остаётся узнаваемым в window picker.
- Settings / minimize / fullscreen / close вынесены в отдельный маленький child `NSPanel` с отдельным window ID. Он не является частью видеохолста.
- Preview остаётся aspect-locked к фактическому входному кадру; fullscreen остаётся настоящим macOS fullscreen.
- Settings → Preview и Preview → Settings теперь доступны прямыми кнопками; добавлены `⌘1` для Settings и `⌘2` для Preview.

## Window lifecycle / tabs

- `NSWindow.allowsAutomaticWindowTabbing = false` глобально.
- Settings, Preview, Preview Controls и Diagnostics используют `tabbingMode = .disallowed`.
- Системные команды `Show/Hide Tab Bar`, `Show All Tabs`, `Merge All Windows`, `Move Tab to New Window` и переключение tab'ов удаляются из menu tree.
- Закрытие Preview по-прежнему не завершает AirPlay/USB transport: поток можно вернуть кнопкой «Показать предпросмотр».

## AirPlay UX

- Неактивный editable-looking receiver-name `TextField` удалён.
- Имя автоматически строится из системного имени Mac (`Host.current().localizedName`) и публикуется как `MirrorLab — <имя Mac>`.
- Status badge теперь различает ожидание, подключение, трансляцию и ошибку.
- Если поток жив, но Preview закрыт, Settings прямо сообщает об этом и предлагает открыть окно.

## USB UX / multi-device

- Проверенный USB media pipeline 0.3.37–0.3.39 не менялся: native compressed stream, VideoToolbox и direct CoreAudio сохранены.
- При одном подключённом iPhone/iPad auto-connect остаётся полностью автоматическим.
- При нескольких устройствах MirrorLab больше не выбирает первое случайное: появляется компактный picker.
- Выбранный USB device ID запоминается; если он снова доступен, MirrorLab использует его автоматически.
- После выбора из picker захват запускается сам — отдельной кнопки Start нет.
- Старый информационный GroupBox «Предпросмотр» удалён из USB UI.

## Later

- Virtual Camera для OBS остаётся обязательной финальной функцией после стабилизации основных AirPlay/USB режимов.
