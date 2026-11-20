# MirrorLab 0.3.47

## Recovery build после 0.3.46

0.3.47 намеренно возвращает AirPlay media path к подтверждённому baseline 0.3.45.

- AirPlay audio player полностью возвращён к логике 0.3.45: без soft-lead servo, без сохранения CoreAudio output через временные type-96 TEARDOWN/SETUP и без дополнительных retry-циклов, которые дали постоянные underflow в 0.3.46.
- Control-port resend, mirror-only YouTube compatibility и faded loss concealment из 0.3.45 сохранены.
- AirPlay video presentation возвращён к 0.3.45. Wake recovery теперь срабатывает только после реальной паузы >= 2 секунд, а не после обычных 650–800 ms encoder/app gaps.
- USB media pipeline не менялся.
- Сохранены безопасные продуктовые изменения 0.3.46: русская локализация системных меню, MirrorLab.icns/AppIcon assets и увеличенный таймаут fallback сворачивания Preview, чтобы AppKit успевал показать нативную Dock-анимацию.
