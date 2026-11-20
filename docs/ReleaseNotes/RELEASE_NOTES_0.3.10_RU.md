# MirrorLab 0.3.10

## AirPlay: low-latency pacing + настоящий display link

- Playout buffer уменьшен с 80 мс до 24 мс: 0.3.9 доказала, что 80 мс сглаживает burst jitter, но заметно ухудшает игровой input-to-photon latency.
- Presentation timeline теперь якорится по времени прихода первого декодированного кадра, а не по первому draw callback окна. Скрытие/торможение окна больше не может добавить сотни миллисекунд ко всей временной шкале.
- После реального stall/reconfiguration stale timeline автоматически re-anchor'ится к свежему кадру вместо ускоренного проигрывания старой очереди (эффект «slow-mo / догоняния»).
- MTKView render timer заменён на CAMetalDisplayLink + CAMetalLayer. Запрашивается диапазон 60–120 Hz и минимальная допустимая render latency (1 frame), чтобы macOS не выбирала стабильный 30-Hz divisor для отдельного окна.
- CAMetalLayer использует два drawable вместо лишнего буферинга; NV12 → Metal zero-copy/BT.709 сохранён.
- Закрытое отдельное окно больше не переиспользуется: при следующем открытии создаётся свежий Metal surface/display link и сразу подхватывается актуальный AirPlay frame.
- USB pipeline не изменён.
