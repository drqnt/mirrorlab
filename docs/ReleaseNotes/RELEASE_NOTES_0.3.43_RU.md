# MirrorLab 0.3.43

0.3.43 — точечный Preview hotfix после теста 0.3.42. Media pipelines AirPlay/USB не менялись.

## Preview: сворачивание

- Исправлен регресс 0.3.42: borderless Preview создавался без `NSWindow.StyleMask.miniaturizable`, поэтому кнопка с минусом и пункт `Свернуть` в контекстном меню могли ничего не делать.
- Preview теперь создаётся с `.miniaturizable`.
- Перед `miniaturize()` capability дополнительно гарантируется программно.
- Для macOS beta добавлен безопасный fallback: если WindowServer не миниатюризировал borderless окно, MirrorLab скрывает только Preview через `orderOut`; вернуть его можно обычной кнопкой `Показать предпросмотр` или через меню Window. Трансляция при этом не останавливается.

## Preview: clean capture controls

- `Скрыть элементы управления` теперь реализован не только через AppKit `isHidden`, но и через observable SwiftUI state: при скрытии chrome физически перестаёт рисоваться.
- AppKit `isHidden`, `alphaValue` и backing layer синхронизируются как дополнительная страховка для window-capture реализаций.
- Правый клик / два пальца по Preview остаётся основным способом переключить clean-capture режим.

## Не менялось

- AirPlay Full HD / Original presentation, FairPlay, crypto, decoder и audio.
- USB capture / VideoToolbox / CoreAudio.
- Lifecycle, permissions, multi-device logic и AirPlay receiver identity из 0.3.41–0.3.42.
- YouTube AirPlay HLS/direct-media playback в 0.3.43 намеренно не добавлялся; это отдельный transport feature.
