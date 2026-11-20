# MirrorLab 0.2.0 — Native Core Rewrite

- UxPlay удалён из runtime, исходников, bootstrap и tests.
- GStreamer/Homebrew больше не нужны для MirrorLab.
- Wi‑Fi mode переименован в AirPlay и работает через новый Swift `AirPlayController`.
- Добавлена native Bonjour-реклама `_airplay._tcp` + `_raop._tcp`.
- Добавлен `Network.framework` TCP control server и собственный parser RTSP/HTTP AirPlay запросов.
- Добавлены binary `/info`, `/stream.xml`, `/pair-setup` bring-up handlers и подробный protocol trace в JSON.
- AirPlay 0.2.0 намеренно останавливается до FairPlay/media layer — это диагностическая ступень native rewrite, не финальный mirroring path.
- USB discovery переписан: теперь ищутся `.external` + `.muxed` CoreMediaIO screen-capture devices вместо общего списка `.video` камер.
- USB системный звук берётся из того же muxed screen device; отдельный iPhone microphone selector удалён.
- В интерфейсе теперь три режима: AirPlay / USB / Приложение.
- Режим «Приложение» оставлен как будущий Direct sender, но не разрабатывается на этом этапе.
