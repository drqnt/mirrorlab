# MirrorLab 0.2.3

Главные изменения:

- USB Preview теперь fan-out: основное окно и отдельное окно получают каждый новый кадр независимо.
- Отдельное Preview-окно принудительно конфигурируется как `fullScreenPrimary`.
- Кнопка «Во весь экран» вызывает настоящий `NSWindow.toggleFullScreen`, то есть macOS должна создавать отдельный fullscreen Space.
- AirPlay проходит FPLY 3.1 `/fp-setup` mode 3 вместо ответа 501.
- После FairPlay MirrorLab принимает первый media `SETUP`.
- Для screen stream type 110 MirrorLab поднимает собственный динамический TCP data port и возвращает его iPhone/iPad.
- В диагностике отображаются mirror TCP port и объём уже пришедших media-байтов.
- H.264/FairPlay key unwrap/декодирование AirPlay-видео ещё не реализованы; 0.2.3 нужен, чтобы довести реальное устройство до собственного media transport и получить точный следующий trace.
