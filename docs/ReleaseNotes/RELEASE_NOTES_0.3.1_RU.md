# MirrorLab 0.3.1 — macOS 27 VideoToolbox build hotfix

- Исправлена сборка `AirPlayVideoDecoder.swift` на Xcode 27 / macOS 27 SDK.
- Swift importer в SDK 27 переименовал enum case `enableAsynchronousDecompression`; MirrorLab теперь задаёт стабильный raw bit `1 << 0`, соответствующий `kVTDecodeFrame_EnableAsynchronousDecompression`.
- Асинхронный hardware VideoToolbox decode сохранён; это не переход на synchronous decode.
- USB media pipeline не изменён.
