# AGENTS.md

## Проект и среда

LocalScribe — локальная запись, расшифровка и итоги встреч, распознавание схем и обезличивание текстов на Apple Silicon (macOS 26+).
Продукты: GUI-приложение `LocalScribe`, helper анализа `LocalScribeWorker` и XPC-сервис загрузки моделей `LocalScribeModelService`.
Приложение на SwiftUI/AppKit собирается и тестируется напрямую через SwiftPM.
ASR использует WhisperKit, MLX или GigaAM на CPU. Диаризация использует SpeakerKit, итоги и схемы — MLX.
[README](README.md) описывает настройку Xcode 27.0, Swift 6.4 и Metal Toolchain. На 17.11.2026 подтверждены Xcode 27.0 (27A266a), SDK macOS 27.0, Swift 6.4 для arm64 и путь к Metal Toolchain (`xcrun --find metal`).
[Package.swift](Package.swift) задаёт tools-version 6.1 и минимум macOS 26.0. Три executable targets используют Swift 5 language mode, библиотеки и тесты — Swift 6.
Три пользовательских архива — записи, схемы и тексты — живут в общем окне с отдельным выделением, группами и поиском каждого раздела.
Поддержка Linux не заявлена. Для локального SpeakerKit включены `InferIsolatedConformances` и `NonisolatedNonsendingByDefault`.

## Карта кода

- [LocalScribe](Sources/LocalScribe/) отвечает за UI, запись и общую очередь через [AppModel](Sources/LocalScribe/AppModel.swift).
- [LocalScribeCore](Sources/LocalScribeCore/) содержит контракты, хранилище и экспорт без зависимости от GUI и ML SDK.
- [LocalScribeWorker](Sources/LocalScribeWorker/) исполняет этапы обработки и пишет артефакты. [LocalScribeModelService](Sources/LocalScribeModelService/Service.swift) скачивает закреплённые файлы по XPC.
- Перед изменением отдельного модуля сверить [карту кода](docs/agents/ProjectReference.md#карта-кода) и [документы по разделам](docs/agents/ProjectReference.md#ключевые-документы).

## Команды

Выполнять из корня пакета на Mac с указанным Xcode/Metal Toolchain. Даты в таблице относятся к конкретным прогонам. Для сборки и XCTest в ограниченной среде потребовался доступ к системному Clang ModuleCache.

| Задача | Точная команда | Статус |
| --- | --- | --- |
| Release executable targets | `swift build -c release -j 4 --force-resolved-versions` | проверено 18.11.2026 при подготовке релиза 2.21.0 (обычная SwiftPM-сборка); статический runtime GigaAM — 17.11.2026 в упаковке 2.20.0 |
| Все XCTest | `swift test -c release -j 4 --force-resolved-versions` | проверено 18.11.2026 в составе релиза 2.21.0 — 970 XCTest, 0 ошибок, 19 опциональных пропусков; 19.11.2026 добавлены 95 тестов в 9 сьютах (фильтрованный release-прогон, 0 ошибок), ожидаемо 1065 XCTest: 369 Core, 375 UI/service, 321 worker/диаризация |
| Один тест | `swift test -c release -j 4 --force-resolved-versions --filter RecordingPlaybackTests/testSummaryStartsPlaybackAndTranscriptClickPreservesPause` | проверено 18.11.2026 — 1 тест, 0 ошибок; 19.11.2026 — 9 сьютов (95 тестов) одним запуском с повторными `--filter` (объединяются по ИЛИ), 0 ошибок. Формат фильтра — `Suite/test` без имени target |
| Python-проверки скриптов | `python3 -m unittest discover -s scripts/tests -v` | проверено 18.11.2026 в составе релиза 2.21.0 — 89 тестов, 0 ошибок, локальные фикстуры без весов и сети |
| Статические проверки CI | `bash scripts/verify.sh --static` | проверено 18.11.2026 в составе релиза 2.21.0 — оба plist валидны, 89 Python-тестов, включая согласованность версии |
| Проверка аудиокодеков | `python3 scripts/format_checks.py` | (не проверено) — отсутствует `Assets/probe/mixed.wav`. В прогоне 26.10.2026 прошло 8/8 вариантов, включая AAC ADTS, см. [ASRModels](docs/ASRModels.md) |
| Путь к executable | `swift build -c release --show-bin-path` | проверено — `.build/out/Products/Release` в этой среде |
| FFmpeg/ffprobe | `bash scripts/build_ffmpeg.sh` | (не проверено) — пересборка C-инструментов и возможная загрузка исходников не выполнялись |
| Упаковка .app | `bash scripts/build_app.sh` | проверено 17.11.2026 для 2.20.0 (сборка 38): пакет собран со статическим runtime GigaAM, строгая проверка подписи прошла |

Обычная SwiftPM-сборка использует заглушку GigaAM для контрактных тестов. Для рабочего backend см. [сборку со статическим runtime](docs/ASRModels.md#gigaam-v3-rnnt).

Для чистой сборки Metal нужен установленный Metal Toolchain. Перед сборкой проверяй текущий путь через `xcrun --find metal`. Если XCBuild вызывает прежнюю точку монтирования, перемести только устаревшее описание `*.xcbuilddata` из `.build/out/Intermediates.noindex/XCBuildData` и повтори сборку. Для проверки кодеков нужны `Assets/tools`, `Assets/probe/mixed.wav` и локальные фикстуры. AAC через Core Audio ранее потребовал разрешённого доступа. Не запускай `swift build --build-tests` после обычного `swift build`: Products может остаться с нетестовой вариацией `LocalScribeCore`, и `@testable import` упадёт с «unable to resolve Swift module dependency»; тесты запускай сразу через `swift test`, он сам пересобирает тестовые вариации.
Источник проверки аудиокодеков — [README](README.md) и [Architecture](docs/Architecture.md); отчёт сохраняется в игнорируемый `TestResults/format-checks.json`.
Источник SwiftPM-сборки — [build_app.sh](scripts/build_app.sh), XCTest — [README](README.md) и [ModelManagement](docs/ModelManagement.md); Python-проверок — [README](README.md); фильтр взят из [RecordingPlaybackTests](Tests/LocalScribeUITests/RecordingPlaybackTests.swift).
В репозитории не найдены команды линта/форматирования Swift и генерации Xcode-проекта. [format_checks.py](scripts/format_checks.py) проверяет аудиокодеки, а не стиль кода.
Генерация каталога моделей описана в [ModelManagement](docs/ModelManagement.md) и [ASRModels](docs/ASRModels.md). Генераторы [lock_models.py](scripts/lock_models.py), [lock_qwen_models.py](scripts/lock_qwen_models.py) и [lock_vibevoice_models.py](scripts/lock_vibevoice_models.py) обращаются к сети и по умолчанию обновляют [models.lock.json](Resources/models.lock.json). Обычная сборка использует готовый каталог. Генераторы в этом прогоне не запускались. Python-загрузчики оборачивают поток лимитом каталожного размера ([download_models.py](scripts/download_models.py) прерывает чтение при превышении), а [catalog_io.py](scripts/catalog_io.py) кэширует ответ только с явным `immutable=True` и читает его с лимитом байтов.

## Переменные окружения

[Переменные сборки и тестовых фикстур](docs/agents/ProjectReference.md#переменные-окружения) читать при упаковке и включении опциональных тестов.

## Макет хранилища

Корень по умолчанию — `~/Library/Application Support/LocalScribe` ([Repository](Sources/LocalScribeCore/Repository.swift)); тесты создают временные корни через `RecordingRepository(root:)`.
- `recordings/<UUID>/` — `manifest.json` (источник истины), `source` (оригинал аудио), `capture` (10-секундные CAF live-записи), `runs/<runId>/` (артефакты worker) и `live-captions.json` (текст вкладки «В эфире»).
- `groups.json` v1 — авторитетный каталог групп записей; `index.json` — вспомогательный индекс.
- `models/` — установленные комплекты моделей; `.partial` публикуется только после проверки размеров и SHA-256.
- Архив схем — сиблинг-ветка того же корня со своим `groups.json` v1 и `items/<UUID>/runs/<runId>/`.
- Архив текстов: `catalog.json` v1, `items/<UUID>/card.json`, `runs/<attemptID>/`, намерения импорта/удаления в `pending/`; настройки — `anonymization/settings.json`.
- [models.lock.json](Resources/models.lock.json) — закреплённый каталог моделей с SHA-256. Способ обновления зависит от профиля.
- `TestResults/` — игнорируемые Gitом отчёты прогонов, тексты и эталоны ASR-экспериментов.
- JSON везде пишется атомарным `Disk.write` с ISO 8601 датами; повреждённые каталоги не заменяются пустыми.

## Ключевые документы

Перед изменением обработки читать [Architecture](docs/Architecture.md), перед работой с захватом — [LiveCapture](docs/LiveCapture.md), перед установкой моделей — [ModelManagement](docs/ModelManagement.md). По остальным разделам см. [ключевые документы](docs/agents/ProjectReference.md#ключевые-документы).

## Архитектура и контракты

- Сохранять один последовательный worker. GUI и worker работают без `network.client`; сеть для загрузки есть только у XPC-сервиса. Он принимает ID профиля/индекс и возвращает файловый дескриптор, не получает архив, аудио или транскрипцию. GUI зовёт сервис только через `remoteObjectProxyWithErrorHandler` (включая `cancel`/`releaseDownload`): синхронный прокси бросает ObjC-исключение на инвалидированном соединении. Подробности — [Architecture](docs/Architecture.md).
- [WorkerSupervisor](Sources/LocalScribe/WorkerSupervisor.swift) и [Worker](Sources/LocalScribeWorker/Worker.swift) используют JSONL v1: команда в stdin, события в выделенном протокольном stdout; обычный stdout worker перенаправлен в stderr.
- EOF отменяет процесс и дочерние процессы. В протокольный канал писать только WorkerEvent; при отмене завершать всю сохранённую группу процессов и дожидаться обоих pipe readers даже после выхода лидера.
- Состояние UI/очереди изолировано `@MainActor` в AppModel и WorkerSupervisor; тяжёлые файловые операции выносятся из главного актора. Сохранять существующие границы actors и `@Sendable`, не отключать проверки concurrency ради сборки. Частые meter/elapsed/status публиковать через `ActivityIndicators`.
- Manifest меняет GUI через `RecordingCoordinator`; worker пишет артефакты в `runs`. Actor сериализует транзакции без приостановки между чтением и публикацией manifest, отдаёт снимки с монотонной ревизией и пакетно обновляет индекс; не возвращать сканирование архива и синхронный I/O в MainActor.
- В [Repository](Sources/LocalScribeCore/Repository.swift) manifest — источник истины, `index.json` — вспомогательный индекс; Core Data/SwiftData здесь нет.
- При изменении групп читать [RecordingGroups](docs/RecordingGroups.md): `groups.json` — отдельный авторитетный каталог версии 1; `index.json` и manifests не хранят принадлежность. Изменения проходят через `RecordingCoordinator`: сначала `Disk.write`, затем снимок с общей ревизией.
- Повреждённый каталог блокирует изменения групп и не заменяется пустым; старые manifests и аудио при миграции не переписываются. Системная «Без темы» всегда последняя.
- Группа назначения фиксируется до запуска записи и до ожидания NSItemProvider/ImportQueue для всего набора файлов, включая повтор дубля. Удалённое назначение заменяется «Без темы», а не текущей группой по умолчанию. Массовый перенос проверяет все UUID перед единственным сохранением; раскрытие всех групп не должно писать каталог повторно без изменений.
- Удаление группы закрепляет её состав через `prepareGroupDeletion`; до первого ожидания отмены блокировать допуск всех затронутых UUID и поздний enqueue. Дождаться их worker, защитить микрофон/финализацию и сохранить порядок чужих заданий.
- Частичный отказ публикует фактически оставшийся архив, сохраняя группу и повреждённые элементы. Для массового удаления записей фиксировать UUID в подтверждении и повторно проверять защиту при выполнении. Удаление группы записей валидирует всех участников до первого удаления: повреждённый участник сохраняет группу и здоровые записи целиком, частичная публикация остаётся только для I/O-отказа в середине цикла удаления.
- Схемы используют собственный `groups.json` версии 1. Повреждённый каталог блокирует изменения групп схем. Удаление только группы переносит схемы в «Без темы». Для удаления вместе со схемами [DiagramCoordinator](Sources/LocalScribeCore/DiagramCoordinator.swift) фиксирует состав через `prepareGroupDeletion`. AppModel блокирует допуск этих заданий и ждёт остановки их worker перед `finishGroupDeletion`. `cancelGroupDeletion` снимает зафиксированное удаление; AppModel вызывает его и текстовый `cancelDeletion()` в catch обёрток удаления.
- При частичном отказе обновлять снимок по оставшимся элементам, сохраняя группу и повреждённые элементы.
- Пакет схем фиксирует группу до загрузки файлов и использует общий [ImportQueue](Sources/LocalScribe/ImportQueue.swift). Запросы URL из Finder запускаются в обработчике drop, а импорт идёт последовательно.
- [DiagramCoordinator](Sources/LocalScribeCore/DiagramCoordinator.swift) сверяет SHA со всем снимком архива. Подтверждённый повтор сохраняет назначение. Если группа удаляется или уже удалена, файл сохраняется в «Без темы».
- Очередь типизирована заданиями `QueueJobID` (`recording(id)`/`diagram(id)`/`text(id)`) в [AppModel](Sources/LocalScribe/AppModel.swift): общие FIFO, слот, `queueGeneration`, паузы и admission с составными ключами; одинаковые UUID разных архивов не смешиваются. Отмена/удаление одного вида не трогают другой.
- Схема без модели стоит вне FIFO в «Ожидает модель», модель схем закрепляется при постановке. Роль моделей `.diagram` не входит в `ModelRole.audioRoles`.
- `WorkerCommand` несёт опциональный дискриминатор `kind: "diagram"` (аудио — прежний формат без kind); worker отвергает неизвестный kind кодом 64 и маршрутизирует схемы после общей инициализации контроля.
- Схемные run'ы версионируются `DiagramRunInfo` (pipeline/prompt/preprocessing), повтор создаёт новый run, поздний completed не публикуется после отмены.
- Обезличивание — третий вид команды `kind: "anonymization"` с `anonymizationPath`: вход `input.json` и результат `result.json` ([AnonymizationRunArtifact](Sources/LocalScribeCore/AnonymizationContracts.swift)) лежат в каталоге попытки; события несут `kind`, jobId карточки и runId попытки, текст/подстановки/имена никогда не попадают в протокольный stdout и события.
- Публикация — только для текущей RUNNING-попытки с совпадающим `expected_result_revision_id`, поздние и чужие завершения результат не меняют.
- Текстовый архив живёт в `texts`: `catalog.json` v1 (группы, принадлежность, порядок импорта, default), `items/<UUID>/card.json`, `runs/<attemptID>/`, намерения импорта/удаления в `pending/`.
- Actor AnonymizationCoordinator сериализует транзакции и снимки с монотонной ревизией; повреждённый каталог блокирует изменения групп; при запуске QUEUED/RUNNING становятся INTERRUPTED, WAITING_MODEL сохраняется.
- Очередь: третий вид `text(id)` делит общий FIFO со слотом записей и схем; карточка без готового профиля стоит вне FIFO в «Ожидает модель».
- При допуске повторно проверяются готовность и размер входа в UTF-8 без BOM (`FAILED/SIZE_LIMIT` с обоими числами), закрепляются RunInput (профиль, комплект, список типов, версия исходника) и lease комплекта до выхода worker.
- Импорт текста сверяет `ImportSource.size` с `max(лимит профиля, AnonymizationInputLimit.maximumCardBytes)` до чтения файла в память; путь restoration ограничен `AnonymizationRestoration.maximumImportFileBytes` до чтения.
- Правка левой панели (`editSource`) отвергается при живой QUEUED/RUNNING-попытке: вход попытки заморожен, а публикация сверяет пары с текущим source. Явный retry (`retryAnonymization`) в замыкании `updateCard` сверяет id и состояние попытки — параллельно допущенное `wakeWaitingTextCards`-задание не должно быть затёрто свежей WAITING_MODEL-попыткой.
- Неякорные строки, целиком лежащие в контекстном padding окна, пропускаются до clamp в [AnonymizationEngine](Sources/LocalScribeWorker/AnonymizationEngine.swift): пустое пересечение с core не должно строить инвертированный Range (фатальный крэш worker без события `failed`).
- Повтор фиксирует исходник при команде/согласии; при уходе в WAITING_MODEL снимок очищается и допуск берёт последнюю сохранённую версию, согласие на замену привязано к ID правой версии.
- `pinned(to:)`, `activeCatalog` и аудио-fingerprint её не видят, готовность схем (`diagramProfile`) независима. Читать [DiagramRecognition](docs/DiagramRecognition.md) перед изменением режима схем.
- JSON сохранять через атомарный `Disk.write` с ISO 8601 датами из [Contracts](Sources/LocalScribeCore/Contracts.swift). Проверять schemaVersion, UUID каталога, длительность, ссылки и fingerprint перед использованием результатов. Run-идентификаторы из персистентного JSON (`RunInfo.id`, `manifest.pendingRunId`) валидируются как UUID до построения путей (`bindLiveTranscript`, `cleanupTemporaryFiles` в [Repository](Sources/LocalScribeCore/Repository.swift)) — конвенция «Check before constructing a path from the persisted identifier»; валидации в `save` нет, тесты сознательно пишут не-UUID значения.
- `Disk.read` не отвергает файл при недоступном `fileSize` (авторитетная проверка — `data.count`), `requireSpace` не блокирует импорт при недоступной метрике тома: недоступная метрика — не исчерпание.
- Все ASR-движки (включая WhisperKit) отбрасывают слова/сегменты с не-конечными (NaN/∞) таймкодами до конвертации в `Int` — крэш расшифровки на дегенеративном аудио недопустим, событие `failed` обязательно.
- [ResultReading](Sources/LocalScribeCore/ResultReading.swift) читает результат целиком: повреждённый финальный JSON нельзя скрывать откатом к checkpoint или показывать частично.
- Сохранять разделение `activeRunId` и `pendingRunId`: неудачный повтор не уничтожает прошлый результат. Изменение поведения pipeline/prompt требует обновить `RunInfo.pipelineVersion` и fingerprint контрольных точек в [SummaryEngine](Sources/LocalScribeWorker/SummaryEngine.swift). [Pipeline](Sources/LocalScribeWorker/Pipeline.swift) отвергает run с несовпадающей `pipelineVersion` на любой стадии, а не только transcribing; `resumeRun` — первый рубеж до постановки задания.
- «Продолжить» вызывает `RecordingRepository.resumeRun`: сохраняет pending run, проверяет его версию, исходник и закреплённый каталог через `ModelCatalog.pinned(to:)` с полными SHA файлов. Несовместимость не создаёт новое задание; для выбранных сейчас моделей предназначено «Обработать заново».
- Выбранные профили фиксируются в `RunInfo.modelIDs`, ForcedAligner Qwen — в `auxiliaryModelIDs`. Старые задания без `modelIDs` используют исходные имена ролей. Сохранять legacy fingerprint и учитывать backend, политику и зависимости новых профилей.
- Глобальный словарь распознавания (один общий список в настройках, только WhisperKit/Qwen3-ASR) закрепляется нормализованным снимком в `RunInfo.recognitionTerms` при создании ASR-задания; непустой снимок входит в fingerprint, run без словаря сохраняет прежнюю формулу. Содержимое словаря не попадает в логи, метрики и события worker. «Пересоздать итоги» снимок не закрепляет.
- Whisper передаёт его через `promptTokens`. Лимит 111 токенов проверяет общий [WhisperDictionary](Sources/LocalScribeWhisperHints/WhisperDictionary.swift) при сохранении настроек с установленным токенизатором и при запуске ASR. Условия повтора без подсказки описаны в [Architecture](docs/Architecture.md). Qwen передаёт словарь через `context` с вырезанными служебными маркерами.
- Изменение выбора моделей не должно запускать ожидающие записи или менять manifests.
- Перед изменением фонового ASR читать [LiveCapture](docs/LiveCapture.md): `recording` относится к микрофону, `captureProcessing` — к обработке; ошибка модели не останавливает микрофон.
- `Manifest.sourceType` отражает зарезервированную конфигурацию захвата (`microphone`/`systemAudio`/`microphone+systemAudio`); единая проверка для live-захвата и валидации live-результатов — предикат `manifest.isCaptureRecording`. Деградация источника фиксируется предупреждением, старые манифесты не переписываются.
- Новая запись сохраняет FIFO и не прерывает текущий worker. Явное «Поднять на верх очереди» меняет только порядок ожидающих заданий.
- Отмена через `AppModel.cancel` сохраняет аудио/результаты и при активном микрофоне меняет только `captureProcessing`.
- Сохранять `queueGeneration`, идентификаторы запросов постановки в очередь и независимые `queuePauses`: отложенный enqueue не должен вернуть отменённое задание после сна/остановки. Образец регрессий — [ProcessingQueueTests](Tests/LocalScribeUITests/ProcessingQueueTests.swift).
- `automaticSummaries` проверяется при переходе к этапу итогов; выключение не отменяет уже запущенную LLM и не запрещает явное «Пересоздать итоги» (`summaryLanguage`/`transcriptSourceRunID`).
- Пауза из-за памяти или защиты микрофона сохраняет очередь для автоматического продолжения. UI отличает её от обычного ожидания и очищает временное сообщение при запуске этапа.
- Перед сном начатая подготовка продолжения инвалидируется. См. [LiveCapture](docs/LiveCapture.md).
- «В эфире» использует локальный SpeechAnalyzer и получает ограниченный поток PCM из того же микса, который пишется на диск. Ручной старт отсекает звук до нажатия. Остановка предрасшифровки сохраняет видимые реплики, а переключение с фонового ASR откладывает его до остановки записи и сохраняет checkpoints. Настройки этих двух режимов взаимоисключающие. См. [LiveCapture](docs/LiveCapture.md).
- В live ASR читать только закрытые CAF; связывать checkpoints с оригиналом через seal, SHA/PCM и непрерывное покрытие окон. Не удалять фрагменты до проверенного присоединения ASR и выхода worker.
- [ResultEditing](Sources/LocalScribeCore/ResultEditing.swift) сохраняет черновик полным новым run и только затем переключает activeRunId. Сохранять ID, таймкоды, участников и порядок оставшихся реплик; при изменении текста удалять старые word timings.
- Ручные итоги без evidence разрешены только для проверенной ручной версии; автоматические требуют основания.
- Markdown-экспорт расшифровки гасит переводы строк сегмента в пробел и экранирует backtick (по образцу `DiagramExport`): текст реплики или имя участника не должны менять структуру документа.
- При изменении плеера и переходов по репликам сверять [контракты воспроизведения](docs/agents/ProjectReference.md#воспроизведение-записей). Частые обновления позиции наблюдают плеер и текст расшифровки напрямую через [RecordingPlayback](Sources/LocalScribe/RecordingPlayback.swift).
- «Пропускать паузы» по умолчанию выключено: при воспроизведении пропускать начальную тишину до первой реплики и промежутки ≥ 1000 мс между концом реплики-абзаца и следующим началом, объединяя перекрытия. В паузе воспроизведения позицию не менять; индекс обновлять при замене расшифровки и сбрасывать при смене источника. Подробности — [контракты воспроизведения](docs/agents/ProjectReference.md#воспроизведение-записей).
- Границы пропускаемых пауз сравнивать в секундах: начало включено, конец исключён. После успешной точной перемотки подавлять повторный автопереход к той же цели в пределах допуска 50 мс, иначе AVPlayer может зациклиться; подробности и сброс маркера — в [контрактах воспроизведения](docs/agents/ProjectReference.md#воспроизведение-записей).
- Кнопки по краям шаговой перемотки переходят к началам реплик, сохраняя паузу/воспроизведение; шаги — 5, 10, 15, 30 и 60 секунд. Модель после статуса расшифровки брать из исходного ASR-run через `transcriptSourceRunID`, а не из текущего выбора моделей. См. [контракты воспроизведения](docs/agents/ProjectReference.md#воспроизведение-записей).
- Пробел без модификаторов — пауза/продолжение плеера, только в активном окне раздела «Записи» с открытой карточкой и доступным аудио (`WorkspaceKeyboardShortcut.Action.togglePlayback`, применяет `ContentView.handleShortcut` к `model.playback`). Ключ не отбирать у живого ввода текста (field editor, редактируемые поля, marked text) и сфокусированных кнопок; слайдеры, сегменты и read-only расшифровка пробел не резервируют, автоповтор игнорировать. Проверяется в WorkspaceKeyboardTests.

## Локальные конвенции и ловушки

Перед изменением захвата, очереди, моделей, любого этапа worker или архивного UI читать раздел [«Локальные конвенции и ловушки»](docs/agents/ProjectReference.md#локальные-конвенции-и-ловушки).

## Тестирование

- [LocalScribeTests](Tests/LocalScribeTests/) проверяет Core, [LocalScribeUITests](Tests/LocalScribeUITests/) — GUI и сервисы, [LocalScribeDiarizationTests](Tests/LocalScribeDiarizationTests/) — SpeakerKit и worker.
- Для AppModel использовать `startServices: false`, отдельные UserDefaults, временный архив через `RecordingRepository(root:)` и тестовый процесс через `workerExecutable`. Образец — [ProcessingQueueTests](Tests/LocalScribeUITests/ProcessingQueueTests.swift).
- Панели, импорт и подтверждения в тестах проходят через подменяемые обработчики. Настоящий NSAlert в тестовом процессе вешает прогон.
- Перед запуском профильных проверок смотреть [тесты и ограничения по разделам](docs/agents/ProjectReference.md#тестирование). Для TCC, записи и реальных моделей читать [MacAcceptance](docs/MacAcceptance.md).

## Выпуск релиза

1. Обновить версию и номер сборки в [Info.plist](Resources/Info.plist), [plist XPC-сервиса](Resources/ModelService-Info.plist) и [AppInfo](Sources/LocalScribe/AppInfo.swift). Версию в [README](README.md) тоже обновить. Согласованность проверяет `bash scripts/verify.sh --static`.
2. Полный прогон перед выпуском: `swift test -c release -j 4 --force-resolved-versions`.
3. Собрать и упаковать `.app`: `bash scripts/build_app.sh` статически линкует runtime GigaAM в worker и добавляет XPC, FFmpeg, bundles и Metal-ресурсы; подпись задаёт `LOCALSCRIBE_SIGN_IDENTITY`, по умолчанию ad-hoc.
4. Иконка генерируется командой `bash scripts/build_icon.sh` из [AppIcon.png](Resources/AppIcon.png) в [AppIcon.icns](Resources/AppIcon.icns); команда проверена в составе упаковки 17.11.2026.
5. Коммит выпуска — `feat:`/`fix:` с необязательной областью и номером версии, как `feat: add recording playback and release LocalScribe 2.18.0`.

## Зависимости и границы изменений

- [Package.swift](Package.swift) фиксирует Argmax OSS 1.1.1, MLX Swift LM 2.31.3, MLX Swift 0.31.6 и Swift Transformers 1.2.1. [Package.resolved](Package.resolved) отслеживается Git. При согласованном обновлении менять manifest и lockfile согласованно. Обычная сборка использует `--force-resolved-versions`.
- **Всегда:** сохранять проверку исходного SHA, модельных хэшей и результатов перед публикацией: от них зависят возобновление и целостность архива. Проверять применимые вложенные AGENTS.md при их появлении.
- **Сначала уточнить, если это не входит в поручение:** изменение entitlements/Info.plist, подписи и схемы хранения — они затрагивают права, распространение и существующие данные. Явное поручение уже является разрешением.
- **Никогда:** не перегенерировать каталог моделей в обычной сборке и не ослаблять sandbox/сетевую изоляцию ради успешного запуска. Менять источник/профили в рамках соответствующей задачи, сохраняя проверку SHA.
- Не добавлять в коммиты кэши, веса и результаты прогонов: [.gitignore](.gitignore) исключает `.build`, `.swiftpm`, `Vendor`, `Assets`, `build`, `dist`, `TestResults`, логи. Основной код находится в Sources; [ThirdParty/SpeakerKit](ThirdParty/SpeakerKit/) отслеживается Git и участвует в сборке, Vendor содержит исключённые сторонние исходники.
- Обновление снимка SpeakerKit требует сверки `upstream.json`, всех локальных patch-файлов, лицензий и тестов по его README; не править `.build/checkouts`.
- В последних коммитах используются `feat:`/`fix:`/`docs:` с необязательной областью; обязательный формат коммитов и PR-шаблон не найдены. [GitHub Actions](.github/workflows/verify.yml) запускает `bash scripts/verify.sh --static`. Локально `bash scripts/verify.sh` дополнительно запускает релизные XCTest.
