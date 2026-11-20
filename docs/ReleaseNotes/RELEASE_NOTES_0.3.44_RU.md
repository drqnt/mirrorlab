# MirrorLab 0.3.44

0.3.44 — compatibility/audio revision после тестов YouTube, TikTok и Instagram на iPad. USB media path и уже устраивающий Full HD AirPlay renderer не менялись.

## YouTube: mirror-only AirPlay capabilities

- MirrorLab больше не рекламирует себя как полноценный AirPlay Video/HLS player, которого в приложении пока нет.
- Из feature mask убраны direct-media capabilities: Video, VideoFairPlay, VideoHTTPLiveStreams, AirPlayVideoPlayQueue и AirPlayFromCloud.
- Screen Mirroring, ScreenRotate, AirPlay audio, FairPlay/authentication и HEVC ScreenMultiCodec для Original сохранены.
- TXT Bonjour, `/info` и новый совместимый `/server-info` используют один и тот же mirror-only feature mask.
- Цель: YouTube должен продолжать локальное воспроизведение на iPad и попадать в обычный screen-mirroring поток с UI, как TikTok/Instagram, вместо попытки передать URL/HLS receiver'у.

## AirPlay audio: redundantAudio loss recovery

- Старый код сразу объявлял sequence gap потерей, а позднюю redundantAudio=2 копию затем выбрасывал как устаревший пакет.
- Добавлен маленький resequencing window только при обнаруженной дыре последовательности; нормальные in-order пакеты по-прежнему декодируются немедленно без постоянного дополнительного jitter buffer.
- Поздняя redundantAudio=2 копия может восстановить пропущенный AAC-ELD packet до декодера.
- Если пакет действительно не восстановился за redundancy horizon, MirrorLab вставляет ограниченное число PCM silence frames в рамках существующего ~150 ms lead ceiling, чтобы одиночная потеря не запускала длинный CoreAudio rebuffer.
- В report добавлены `audioLateRecoveredPackets` и `audioConcealedFrames`, чтобы следующий TikTok/Instagram тест показал, работает ли recovery на реальном Wi-Fi.
- Startup preroll (~65 ms) и hard lead ceiling (~150 ms) намеренно не увеличены: цель — убрать глитчи без заметного роста задержки.

## Preview / USB / renderer

- Clean-capture toggle и minimize hotfix из 0.3.43 сохранены.
- AirPlay Full HD CAMetalDisplayLink/presentation path не менялся.
- USB native compressed VideoToolbox и direct CoreAudio path не менялись.
