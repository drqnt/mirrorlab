# MirrorLab 0.3.48

0.3.48 — небольшой UX-релиз поверх стабильного 0.3.47. Media timing, AirPlay negotiation, USB capture и video renderer намеренно не менялись.

## Громкость MirrorLab

- В Preview controls добавлена новая крайняя правая кнопка громкости.
- По нажатию открывается компактный popover с ползунком 0–100% и текущим процентом.
- Регулятор влияет только на звук MirrorLab; системная громкость macOS и другие приложения не затрагиваются.
- Один общий уровень применяется и к AirPlay AAC-ELD → PCM, и к USB PCM path.
- На новой установке используется безопасный default 65%, чтобы подключённый iPhone/iPad не начинал играть на полной громкости Mac.
- Выбранное значение сохраняется в `UserDefaults` (`MirrorLab.OutputVolume`) между запусками.
- Gain применяется на serial PCM producer queue перед записью в bounded ring. Realtime CoreAudio render callback остаётся без новых блокировок и без изменения latency.

## Distribution

- Исправленный `BUILD_MIRRORLAB_BETA.command` сохранён в проекте. На Mac с Xcode Beta он собирает Release ARM64 standalone `MirrorLab Beta.app` и ZIP для другого Apple Silicon Mac.

## Не менялось

- AirPlay audio buffering/retransmission baseline 0.3.47.
- YouTube mirror-only compatibility.
- AirPlay video renderer/presentation.
- USB capture/decode path.
- Preview resize/fullscreen/clean-capture behavior.
