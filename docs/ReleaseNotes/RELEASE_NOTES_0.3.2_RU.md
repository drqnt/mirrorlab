# MirrorLab 0.3.2 — modern AirPlay mirror framing

- Исправлен parser 128-byte AirPlay mirroring headers по реальному iPadOS wire-format.
- `packet[4]` теперь трактуется как основной type, а `packet[5]` — как subtype/flags; IDR `00 10` больше не считается неизвестным type.
- H.264 codec configuration с современным option `0x0116` (`16 01`) принимается штатно.
- Добавлены варианты `0x0156` для sleeping H.264 и `0x011E/0x015E` для HEVC codec headers.
- Streaming report type `05 00` принимается как telemetry и больше не ломает framing.
- Старый `0x0006/0x001E` формат остаётся совместимым там, где он встречается.
- USB pipeline не изменён.
- FairPlay session-key unwrap остаётся следующим media-layer шагом; до него encrypted H.264 не декодируется.
