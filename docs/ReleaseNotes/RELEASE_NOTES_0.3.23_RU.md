# MirrorLab 0.3.23 — macOS 27 AudioBufferList compile fix

База: 0.3.22. Media pipeline не изменён.

## Исправлено

- `AVAudioPCMBuffer.mutableAudioBufferList` в macOS 27 SDK имеет тип `UnsafeMutablePointer<AudioBufferList>`.
- Перед доступом к `count` и индексированием указатель теперь оборачивается в `UnsafeMutableAudioBufferListPointer`.
- Это устраняет ошибку компилятора `UnsafeMutablePointer<AudioBufferList> has no member count`.

## Без изменений

- AirPlay video path остаётся восстановленным из 0.3.10.
- AAC-ELD → PCM → CoreAudio low-latency архитектура не менялась.
