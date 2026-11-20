# MirrorLab 0.3.6

## AirPlay: переключение источника без взаимного повреждения сессий

- Добавлен один активный владелец AirPlay media pipeline.
- Новый iPhone/iPad при начале FairPlay атомарно получает pipeline; старый mirror/audio transport закрывается до смены ключа.
- Каждой AirPlay-сессии присваивается `sessionGeneration`; mirror TCP connections запоминают поколение и поздние пакеты старого устройства отбрасываются.
- Поздний `SETUP`/`TEARDOWN` старого устройства больше не может сбросить FairPlay/AES/VideoToolbox или вернуть placeholder поверх картинки нового источника.
- VideoToolbox callbacks помечены generation, чтобы запоздавший decoded frame старой сессии не мог вернуть `hasLiveVideo`.
- USB media pipeline не менялся.

Следующие этапы после подтверждения этого фикса: оптимизация AirPlay FPS/frame pacing, затем AirPlay audio decrypt/decode/NTP sync → CoreAudio.
