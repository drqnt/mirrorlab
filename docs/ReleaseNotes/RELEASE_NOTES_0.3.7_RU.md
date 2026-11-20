# MirrorLab 0.3.7

Небольшой housekeeping-релиз после успешного теста active-source takeover в 0.3.6.

- `bootstrap.command` после успешной сборки и запуска MirrorLab больше не ждёт Enter: Finder-запущенная вкладка Apple Terminal закрывается автоматически.
- При ошибке сборки Terminal по-прежнему остаётся открытым и просит Enter, чтобы сообщение не исчезло до диагностики.
- Все release notes перенесены из корня проекта в `docs/ReleaseNotes/`.
- Вспомогательный HTML-тест задержки перенесён из `Tools/latency-test/` в `Tools/Diagnostics/LatencyTest/`; скрипт запуска обновлён.
- LatencyTest оставлен как диагностический инструмент для будущего сравнения USB / AirPlay / Companion по реальной end-to-end задержке.
- AirPlay media pipeline, active-source takeover и USB capture в этом релизе не менялись.

Следующие большие задачи: AirPlay FPS/frame pacing, затем AirPlay audio decode/sync.
