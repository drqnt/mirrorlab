# MirrorLab 0.3.42

0.3.42 — Preview interaction/UI polish после теста 0.3.41. AirPlay Full HD presentation path и USB media pipeline намеренно не менялись.

## Preview

- Возвращены компактные кнопки управления прямо поверх Preview: Settings, Minimize, Fullscreen, Close.
- Кнопки теперь являются частью самого Preview, а не отдельным дочерним `NSPanel`, поэтому больше не возникает конфликтов focus/order между двумя окнами.
- Правый клик / два пальца по Preview открывает нативное контекстное меню:
  - Показать настройки;
  - Свернуть;
  - Полный экран / выйти из полноэкранного режима;
  - Скрыть / показать элементы управления;
  - Прекратить трансляцию, если поток активен;
  - Закрыть предпросмотр.
- Для Discord/OBS предусмотрен clean-capture режим: перед захватом пользователь скрывает controls через правый клик; тогда в окне остаются только video pixels.
- Исправлен ручной resize: окно сохраняет точное соотношение сторон источника на каждом шаге drag, включая углы, без накопления геометрического drift.
- Borderless capture-surface, квадратные углы, отсутствие title bar/shadow, fullscreen и Window-menu команды сохранены.

## Settings UI

- `Прекратить трансляцию` теперь оформлена как настоящая bordered destructive button с иконкой stop, а не как красная текстовая ссылка.
- `Возобновить USB` также оформлена как обычная bordered button.

## Не менялось

- AirPlay Full HD 60 FPS display/presentation path из 0.3.40/0.3.41.
- AirPlay FairPlay/crypto/decoder/audio.
- USB screen capture, VideoToolbox и direct CoreAudio path.
- Lifecycle USB ↔ AirPlay, permissions, multi-device selection и receiver-name migration из 0.3.41.
