# MirrorLab 0.2.4

Главные изменения:

- AirPlay FairPlay FPLY 3.1 теперь отвечает на legacy mode 0, 1, 2 и 3, а не только mode 3.
- Исправлен конкретный iPadOS 18 trace `...020001BB`: mode 1 больше не обрывает `/fp-setup`.
- Следующая ожидаемая стадия после первого `/fp-setup` — второй 164-байтный FPLY request, затем `SETUP` и mirror TCP.
- В USB UI оставлена одна кнопка «Отдельное окно».
- Preview теперь создаётся как обычный AppKit `NSWindow` со стандартными titled/closable/miniaturizable/resizable стилями.
- Зелёная кнопка Preview должна штатно входить/выходить из настоящего macOS fullscreen Space; отдельная кнопка fullscreen удалена.
- Fan-out USB-кадров сохранён, поэтому embedded preview и отдельное Preview получают живые кадры параллельно.
- Удачный USB video/audio pipeline намеренно не менялся в этой версии.
