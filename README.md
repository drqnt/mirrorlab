# MirrorLab — current development history

> **0.3.50 звук:** буфер звука AirPlay больше не залипает на ~220 мс (пакеты тишины, маскировка потерь, сброс излишка); «Буфер Wi-Fi» управляет и звуком; в настройках видно устройство вывода и его задержку; подробности — docs/ReleaseNotes/RELEASE_NOTES_0.3.50_RU.md.
>
> **0.3.49 Wi-Fi:** AirPlay-видео получило адаптивный буфер Wi-Fi (Мин. задержка / Баланс / Плавность) вместо фиксированных 40 мс от одного кадра; Preview больше не замерзает после смены качества; подробности — docs/ReleaseNotes/RELEASE_NOTES_0.3.49_RU.md.
>
> **0.3.48 beta UX:** стабильный 0.3.47 media path сохранён; добавлен собственный регулятор громкости MirrorLab для AirPlay и USB.

0.3.30 stays on the stable 0.3.28/0.3.29 AirPlay architecture. It does not change FairPlay, AES, H.264 parsing, VideoToolbox, CVDisplayLink ownership, Metal, External Preview ownership, or the symmetric 180 ms timeline re-anchor.

Changes:
- video presentation margin: 24 ms → 40 ms (about one extra 60-fps source frame) to absorb clustered packet-arrival gaps without a large media buffer;
- audio startup preroll: ~35 ms → ~45 ms;
- audio maximum local lead: ~80 ms → ~100 ms.

The goal is to reduce the clustered micro-hitches still visible in 0.3.29 and eliminate the audio crackle caused by the too-aggressive 35/80 ms policy, while staying substantially lower-latency than the older 60/120 ms audio baseline.


## 0.3.31
- AirPlay ScreenMultiCodec (feature bit 42) advertised; native VideoToolbox path now accepts both avcC/H.264 and hvcC/HEVC codec configuration while keeping 1080p60 negotiation.
- No resolution/FPS UI yet; Original mode remains future work.
- Audio keeps ~45 ms startup preroll but raises the hard PCM lead ceiling to ~150 ms so short arrival bursts are not trimmed as aggressively.
- 0.3.28 symmetric presentation re-anchor and current CVDisplayLink/Metal renderer remain unchanged.


## 0.3.32
- AirPlay video controls: 720p / Full HD / Original and 30 / 60 FPS.
- Original is a 4K-class high-resolution AirPlay request with ScreenMultiCodec/HEVC enabled; actual sender dimensions and codec remain observable in the report.
- 720p and Full HD stay on the proven H.264 negotiation path.
- Audio startup/rebuffer now waits for six AAC-ELD packets (~65 ms at 44.1 kHz) while retaining ~150 ms burst headroom.
- Audio diagnostics now split underflow, overflow trimming and converter failures.


## 0.3.33
- Fixes Original/HEVC configuration: iOS/iPadOS sends a 0x011E `hvc1` sample entry that wraps `hvcC`; MirrorLab now unwraps it before creating the VideoToolbox HEVC format.
- Optimizes the mirror TCP hot path by avoiding dictionary Data COW and per-frame front-buffer deletion.
- Adds bounded receive / packet-arrival / decoded-frame gap telemetry for 60 FPS frame-time diagnosis.
- Audio and presentation latency policy are unchanged from 0.3.32.


## 0.3.34
- AirPlay receiver auto-starts with the app; quality/FPS changes automatically re-publish the receiver.
- USB capture now prioritizes the highest CoreMediaIO screen resolution and uses inputPriority, selecting up to 60 FPS at that native format.
- USB report includes the screen device's full format/FPS inventory.
- USB audio no longer uses AVSampleBufferRenderSynchronizer; capture PCM now feeds a tiny direct CoreAudio DefaultOutput ring for wired low latency.


## 0.3.35
- Fixes the macOS build by removing the unavailable `AVCaptureSession.Preset.inputPriority`; USB screen capture continues to select the highest device `activeFormat` directly.
- AirPlay Original is now source-device-aware. The first pre-SETUP `/info` uses a 2560×1440 HEVC-capable bootstrap; after SETUP exposes the sender model identifier, the next `/info` requests that model's native display pixel resolution.
- Unknown models fall back to 2560×1440 rather than forcing 4K.
- Full HD / 720p AirPlay media paths and the USB low-latency audio path are otherwise unchanged.


## 0.3.36
- USB Original now inspects the underlying CoreMediaIO device/streams and requests the highest real CMIO video format instead of trusting the synthetic AVFoundation 0×0 format.
- Reports the actual incoming USB CVPixelBuffer dimensions so requested vs delivered resolution is measurable.
- External preview windows now follow transport lifecycle: final AirPlay session end, USB capture stop/disconnect, or transport-mode switch retires the old preview. Temporary AirPlay encoder reconfiguration does not.


## 0.3.37
- USB Original switches `AVCaptureVideoDataOutput` to documented device-native output (`videoSettings = [:]`) instead of forcing 420v.
- Native compressed H.264/HEVC USB samples are decoded with hardware VideoToolbox into the existing Metal frame store.
- CMIO probing now checks current, preferred, available, and still-image format descriptions plus current/preferred frame-rate properties.
- The AirPlay pipeline and low-latency USB/AirPlay audio paths are unchanged.


## 0.3.38
- USB privacy hardening: discovery now accepts only iPhone/iPad external muxed screen endpoints; the old fallback to the first arbitrary external muxed device is removed.
- Start-time guard rejects any stale/non-iOS capture-device selection before creating AVCaptureDeviceInput.
- Camera permission copy and UI now state the macOS behavior accurately: wired iPhone/iPad screen capture lives in the Camera privacy bucket, but MirrorLab does not select the built-in Mac camera.
- USB native compressed 1718×1200 H.264 path, VideoToolbox decode, Metal rendering, and low-latency CoreAudio remain unchanged.



## 0.3.50
- AirPlay audio: AAC-ELD silence packets now keep RTP sequencing (they were dropped and every quiet moment was treated as a long loss padded to the 220 ms cap).
- Concealment restores only the preroll cushion; holes over 8 packets are not padded.
- Adaptive cushion: floor tracked over ~1.5 s, surplus drained with 2-6 % time compression, underruns add decaying margin; shares the "Буфер Wi-Fi" mode.
- Output device name/transport/latency measured via CoreAudio and shown in Settings; warning for Bluetooth/AirPlay/virtual outputs; 256-frame IO buffer requested.
- Report splits audio latency (receiver buffer, output device, sender sync/skew).

## 0.3.49
- AirPlay video: adaptive Wi-Fi playout clock (sliding-minimum base + held jitter percentile) replaces the one-frame +40 ms anchor and the 180 ms queue-clearing reset; frame selection uses CAMetalDisplayLink targetPresentationTimestamp.
- New "Буфер Wi-Fi" setting: Мин. задержка 25–60 ms / Баланс 40–120 ms / Плавность 70–250 ms, switchable live.
- Fixes a Preview freeze after quality/FPS change or sender takeover (presentation sequence no longer restarts at 0).
- Mirror parser trusts TCP framing for in-sequence headers (protects AES-CTR sync); buffer cap now above max payload.
- Mirror TCP socket uses serviceClass .interactiveVideo; a ProcessInfo latency-critical activity prevents App Nap and display sleep while streaming.

## 0.3.48
- Добавлен app-local регулятор громкости для AirPlay и USB; системная громкость macOS не изменяется.
- Кнопка громкости расположена самой правой в Preview controls и открывает компактный popover со Slider 0–100%.
- Начальная громкость на новой установке — 65%; значение сохраняется в UserDefaults между запусками.
- Gain применяется к PCM на producer queue до realtime CoreAudio callback, поэтому audio latency/buffering 0.3.47 не менялись.
- Release builder сохранён в корне проекта для standalone Beta-сборки на macOS.


## 0.3.47
- AirPlay advertises mirror-only video capabilities: direct Video/HLS/play-queue/cloud playback bits are removed while Screen Mirroring, audio, authentication and Original HEVC ScreenMultiCodec remain.
- `/server-info` now returns the same mirror-only capability mask as Bonjour and `/info`, targeting YouTube's tendency to leave screen mirroring for an unsupported direct-media session.
- AirPlay AAC-ELD uses a loss-only three-sequence reorder window so `redundantAudio=2` copies can recover late packets before decode.
- Truly missing packets get bounded PCM silence concealment instead of immediately triggering a long rebuffer; steady-state startup/lead latency is unchanged.
- Reports expose late recovered audio packets and concealed frames.
- Preview hotfix, Full HD AirPlay renderer, and USB media pipeline remain unchanged.

## 0.3.41

- Preview больше не использует overlay-controls: чистый borderless surface снова вручную ресайзится с сохранением aspect ratio и активируется с первого клика.
- `Прекратить трансляцию` останавливает текущую AirPlay/USB media session; USB можно возобновить без переподключения.
- Переключение AirPlay ↔ USB теперь выполняет полный teardown предыдущего транспорта.
- USB permission UX различает first-request и denied/restricted, умеет открыть Privacy & Security → Camera и перепроверяет разрешение после возврата.
- Multi-USB выбор больше не хранится между изменениями физического набора устройств; live source switch доступен через Window → USB-источник.
- AirPlay receiver name получает одноразовую identity migration, чтобы iOS/iPadOS перестали показывать старое cached имя.


## 0.3.40
- AirPlay primary renderer returns to the layer-owned `CAMetalDisplayLink` path from the 0.3.10 golden-smooth build while preserving the current zero-copy decoder/Metal pipeline and 40 ms bounded realtime scheduler.
- Presentation-drop accounting resets at each new AirPlay sender session instead of leaking cumulative drops across sessions.
- Preview is now a clean borderless, shadowless, aspect-locked capture surface; its title remains metadata for OBS/Discord pickers while local Settings/fullscreen/minimize/close controls live in a separate window.
- Finder-style window tabs are globally disabled and tab commands are removed.
- AirPlay receiver name is derived from the Mac's system name instead of a hard-coded user name.
- Settings now has live connection states and a direct Preview button; Preview has a direct Settings control plus Cmd-1 / Cmd-2 window navigation.
- USB keeps the proven media path; one wired device auto-connects, while multiple wired iOS devices trigger an explicit remembered device picker instead of arbitrary selection.
- Virtual camera output remains intentionally deferred until the core product is stable.
