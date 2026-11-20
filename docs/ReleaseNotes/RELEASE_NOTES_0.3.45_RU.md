# MirrorLab 0.3.45

0.3.45 — финальная аудио-ревизия перед упаковкой полноценного macOS-приложения. Видео, YouTube mirror-only policy, USB capture и UI не менялись.

## AirPlay audio: настоящий RTP control-port recovery

- MirrorLab теперь сохраняет `controlPort`, который iPad сообщает в AirPlay type-96 SETUP, и открывает отдельный UDP control transport к sender'у.
- При обнаружении дырки RTP sequence receiver немедленно отправляет стандартный AirPlay/RAOP range-resend request: 8 байт, payload type `0xD5`, missed sequence + count.
- Retransmitted audio packet type 86 теперь реально принимается и разбирается с корректным 4-byte resend prefix. В 0.3.44 control UDP был открыт, но media-датаграммы этого канала фактически не участвовали в playback.
- Resend-ответ принимается как через объявленный receiver control port, так и через outbound resend connection, чтобы не зависеть от того, куда конкретная версия iOS возвращает retransmission.
- В report добавлены `audioResendRequests` и `audioRetransmittedPackets`.

## Gap handling без резких щелчков

- Loss-only reorder window увеличен до 6 AAC-ELD packets (~65 ms): постоянной задержки на нормальном in-order потоке это не добавляет, окно включается только при реальной дырке.
- Startup/rebuffer margin теперь около 76 ms — достаточно, чтобы пережить один локальный resend RTT, но всё ещё на порядок меньше старого ~1 s audio renderer path.
- Краткие Wi-Fi bursts больше не режутся на 150 ms: hard lead ceiling поднят до ~220 ms, чтобы очередь могла естественно стечь вместо сотен `discardOldest` на музыкальном контенте.
- Если retransmission всё-таки не пришёл, concealment теперь использует короткий fade-out/fade-in, а не жёсткий блок цифрового нуля. Это должно убрать неприятные clicks/pops на TikTok/YouTube.

## Что не менялось

- YouTube mirror-only AirPlay capabilities из 0.3.44 сохранены без изменений.
- Full HD / Original video renderer не менялся.
- USB native compressed VideoToolbox + direct CoreAudio path не менялся.
- Preview/UI/UX не менялись.
