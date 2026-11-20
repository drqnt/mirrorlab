# MirrorLab 0.2.5

## AirPlay
- Исправлен следующий реальный negotiation blocker с iPadOS 18: stream type 96 теперь получает собственные UDP data/control ports вместо пустого `streams`.
- В ответ type 96 возвращается `streamConnectionID`, если он был в запросе.
- Добавлен native UDP ingress/counters для realtime audio.
- Добавлен parser AirPlay screen TCP packets: 128-byte header + payload.
- Отдельно считаются H.264 packets (type 0), avcC config (type 1), heartbeat (type 2) и malformed input.
- Диагностика сохраняет avcC summary, первый video payload prefix, `streamConnectionID`, encrypted setup material и FairPlay key message.
- Это диагностический media bring-up: encrypted H.264 ещё не отправляется в VideoToolbox.

## USB
- Media pipeline не изменён: сохраняем стабильную картинку/звук из 0.2.4.
