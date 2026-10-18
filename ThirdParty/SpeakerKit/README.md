# SpeakerKit с исправлением дополнения хвоста

Отслеживаемая Git копия только `Sources/SpeakerKit` из Argmax OSS 1.1.1,
revision `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`.
Источник: https://github.com/argmaxinc/argmax-oss-swift/tree/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/SpeakerKit .
Исходные SHA-256 каждого файла перечислены в `upstream.json`.

SwiftPM компилирует эту копию как `LocalScribeSpeakerKit`; worker использует
её для диаризации и технического probe. WhisperKit и ArgmaxCore остаются
из закреплённой зависимости в `Package.resolved`. Исходный продукт SpeakerKit
не подключён к worker. Сборка не меняет `.build/checkouts` и не применяет патчи
после разрешения зависимостей; копия включается в исходный дистрибутив.

Единственное изменение SDK — `SpeakerSegmenterModel.reflectTail` и его вызов
перед `AudioProcessor.padOrTrimAudio`; точный diff — `tail-reflection.patch`.
В неполном последнем блоке реальный звук дополняется попеременно обратными
и прямыми копиями до 30 секунд. Пустой и полный блоки не меняются.
`waveformLength`, stride, маски embedder и глобальная кластеризация сохранены.
Причина и эксперимент описаны в https://github.com/argmaxinc/argmax-oss-swift/issues/485 .

При обновлении upstream сверить `Package.resolved` и `upstream.json`, заменить
снимок из выбранной ревизии, проверить необходимость патча и повторить
`LocalScribeDiarizationTests`, в том числе локальный регрессионный пример.
Изменение поведения требует новой `RunInfo.pipelineVersion`.

Лицензия MIT и исходные уведомления сохранены в `LICENSE` и `NOTICES`;
`scripts/licenses.py` включает их в `.app` независимо от наличия этой копии
в кэше SwiftPM. Веса моделей здесь отсутствуют и не изменены.
