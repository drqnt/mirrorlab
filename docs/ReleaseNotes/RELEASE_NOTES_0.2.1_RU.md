# MirrorLab 0.2.1 — Build Fix

- Исправлена ошибка компиляции `AirPlayController.swift` в Xcode 27 beta: response-builder вызовы теперь явно квалифицированы как `AirPlayResponse.ok`, `AirPlayResponse.badRequest` и `AirPlayResponse.notImplemented`.
- Причина: параметр `send(response:)` имеет тип `Data`, поэтому shorthand `.ok/.badRequest/.notImplemented` Swift пытался разрешить как static members типа `Data`.
- Добавлен regression-test, запрещающий неоднозначные `send(response: .…)` вызовы.
- Версия приложения и Xcode metadata обновлены до 0.2.1 / build 9.
- Архитектура 0.2.0 не менялась: UxPlay/GStreamer отсутствуют; AirPlay — native bring-up, USB — CoreMediaIO muxed screen path.
