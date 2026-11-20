# MirrorLab 0.3.4

- Исправлена сборка `EmbeddedFairPlayProvider.swift` на Xcode 27 / Swift с проверкой exclusivity.
- Размеры выходных буферов теперь сохраняются до `withUnsafeMutableBytes`, поэтому внутри mutable access нет повторного чтения `Data`.
- AirPlay media pipeline 0.3.3 сохранён без изменений: embedded PlayFair → AES-CTR → VideoToolbox → Metal.
- USB media pipeline не менялся.
