# SpeakerKit с локальными исправлениями

Отслеживаемая Git копия только `Sources/SpeakerKit` из Argmax OSS 1.1.1,
revision `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`.
Источник: https://github.com/argmaxinc/argmax-oss-swift/tree/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/SpeakerKit .
Исходные SHA-256 каждого файла перечислены в `upstream.json`.

SwiftPM компилирует эту копию как `LocalScribeSpeakerKit`; worker использует
её для диаризации и технического probe. WhisperKit и ArgmaxCore остаются
из закреплённой зависимости в `Package.resolved`. Исходный продукт SpeakerKit
не подключён к worker. Сборка не меняет `.build/checkouts` и не применяет патчи
после разрешения зависимостей; копия включается в исходный дистрибутив.

Исправление дополнения хвоста — `SpeakerSegmenterModel.reflectTail` и его вызов
перед `AudioProcessor.padOrTrimAudio`; точный diff — `tail-reflection.patch`.
В неполном последнем блоке реальный звук дополняется попеременно обратными
и прямыми копиями до 30 секунд. Пустой и полный блоки не меняются.
`waveformLength`, stride, маски embedder и глобальная кластеризация сохранены.
Причина и эксперимент описаны в https://github.com/argmaxinc/argmax-oss-swift/issues/485 .

`inference-errors.patch` применяется после `tail-reflection.patch` и устраняет
подавление ошибок segmenter/embedder. Оба этапа используют throwing task groups;
успех требует каждого ожидаемого индекса блока ровно один раз. Пустой список
embeddings после успешного inference означает тишину и учитывается как завершённый
блок. Ошибка завершает stream, отменяет соседние задачи и выходит после их
завершения. Inference ожидается в задаче вызывающего кода без фонового `Task`.
Полные ASR-контрольные точки и прежний active run сохраняются; worker не публикует
`transcript.json` при сбое. Текущая версия этапа — `diarization3`.

При обновлении upstream сверить `Package.resolved` и `upstream.json`, заменить
снимок из выбранной ревизии, проверить необходимость обоих патчей и повторить
`LocalScribeDiarizationTests`, в том числе локальный регрессионный пример.
Изменение поведения требует новой `RunInfo.pipelineVersion`.

Лицензия MIT и исходные уведомления сохранены в `LICENSE` и `NOTICES`;
`scripts/licenses.py` включает их в `.app` независимо от наличия этой копии
в кэше SwiftPM. Веса моделей здесь отсутствуют и не изменены.
