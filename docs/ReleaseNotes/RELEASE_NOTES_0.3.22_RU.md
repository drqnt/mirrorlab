# MirrorLab 0.3.22 — macOS 27 CoreAudio callback compile fix

Дата: 2026-09-03

## Что изменено

- Исправлена единственная ошибка сборки 0.3.21 в `AirPlayLowLatencyAudioPlayer.swift`.
- В macOS 27 SDK параметр `refCon` у `AURenderCallback` импортируется как `UnsafeMutableRawPointer`, а не Optional. Удалён некорректный `guard let refCon`.
- Логика видео и аудио не менялась: это тот же recovery-video path от 0.3.10 и тот же AAC-ELD → PCM → CoreAudio low-latency path из 0.3.21.
- Build number: 36.

## Цель теста

Сначала подтвердить успешную компиляцию и запуск на macOS 27/Xcode beta, затем проверить плавность восстановленного 0.3.10 video path и задержку нового PCM audio path.
