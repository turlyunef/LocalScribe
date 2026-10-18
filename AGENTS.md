# AGENTS.md

## Проект и среда

LocalScribe — локальная запись, расшифровка и итоги встреч для Apple Silicon, macOS 26+.
SwiftPM-пакет без Xcode-проекта; GUI на SwiftUI/AppKit, анализ через WhisperKit, SpeakerKit и MLX.
Среда из [README](README.md): Xcode 27.0, Swift 6.4, Metal Toolchain 27A266a; Xcode/Swift подтверждены 18.10.2026.
[Package.swift](Package.swift) задаёт tools-version 6.1, минимум macOS 26.0 и Swift 5 language mode для трёх executable targets; Core, локальный SpeakerKit и тесты используют режим Swift 6; для SpeakerKit включены `InferIsolatedConformances` и `NonisolatedNonsendingByDefault`. Поддержка Linux не заявлена.

## Карта кода

- [LocalScribe](Sources/LocalScribe/) — UI, запись микрофона, очередь, управление manifest и запуск worker. Точка композиции — [AppModel](Sources/LocalScribe/AppModel.swift).
- [LocalScribeCore](Sources/LocalScribeCore/) — Codable/Sendable-контракты, файловое хранение, модели, аудио и экспорт; без зависимости от GUI и ML SDK.
- [LocalScribeWorker](Sources/LocalScribeWorker/) — этапы анализа; [Pipeline](Sources/LocalScribeWorker/Pipeline.swift) и [SummaryEngine](Sources/LocalScribeWorker/SummaryEngine.swift) — actors.
- [LocalScribeModelService](Sources/LocalScribeModelService/Service.swift) — XPC-загрузчик закреплённых файлов; [CWorkerIsolation](Sources/CWorkerIsolation/WorkerIsolation.c) — проверка/ограничение сети worker.
- [LocalScribeSpeakerKit](ThirdParty/SpeakerKit/) — отслеживаемый снимок SpeakerKit 1.1.1 с локальными исправлениями хвоста, ошибок inference и backpressure; worker использует его вместо upstream-продукта SpeakerKit.
- [Resources](Resources/) — plist, entitlements, лицензии, каталог моделей. Сборка .app и ресурсов — в [scripts](scripts/).

## Команды

Выполнять из корня пакета на Mac с указанным Xcode/Metal Toolchain. Ниже статус проверки 18.10.2026; SwiftPM пишет служебные кэши вне репозитория; для запуска в ограниченной файловой среде потребовалось отдельное разрешение на доступ к ним.

| Задача | Точная команда | Статус |
| --- | --- | --- |
| Release executable targets | `swift build -c release -j 4 --force-resolved-versions` | проверено — сборка успешна с имеющимися артефактами; чистая сборка Metal не подтверждена |
| Все XCTest | `swift test -c release -j 4 --force-resolved-versions` | проверено — 176 XCTest: 95 Core, 54 UI/service, 27 диаризации; 0 ошибок, 2 модельных пропуска |
| Один тест | `swift test -c release -j 4 --force-resolved-versions --filter CoreTests/testAudioEngineNotificationDoesNotImplyMicrophoneChange` | проверено — выполнен 1 тест, 0 ошибок |
| Путь к executable | `swift build -c release --show-bin-path` | проверено — `.build/out/Products/Release` в этой среде |
| FFmpeg/ffprobe | `bash scripts/build_ffmpeg.sh` | (не проверено) — пересборка C-инструментов и возможная загрузка исходников не выполнялись |
| Упаковка .app | `bash scripts/build_app.sh` | (не проверено) — копирует ресурсы и подписывает .app, подпись в этой задаче не запускалась |

Команда `xcrun metal --version` запущена с ошибкой: Metal Toolchain отсутствует. Успех текущей сборки с имеющимися Metal-артефактами не подтверждает чистую сборку.
Источник SwiftPM-сборки — [build_app.sh](scripts/build_app.sh), тестов — [README](README.md) и [ModelManagement](docs/ModelManagement.md); фильтр взят из [CoreTests](Tests/LocalScribeTests/CoreTests.swift).
В репозитории не найдены команды линта/форматирования Swift и генерации Xcode-проекта. [format_checks.py](scripts/format_checks.py) проверяет аудиокодеки, а не стиль кода.
Генератор каталога `python3 scripts/lock_models.py` — (не проверено): обращается к сети и перезаписывает [models.lock.json](Resources/models.lock.json); для обычной сборки не нужен.
Иконка генерируется командой `bash scripts/build_icon.sh` из [AppIcon.png](Resources/AppIcon.png) в [AppIcon.icns](Resources/AppIcon.icns); (не проверено) — отслеживаемый ресурс в этой задаче не перезаписывался. Упаковщик вызывает генерацию автоматически.
SwiftPM-сборка не создаёт готовую .app. [build_app.sh](scripts/build_app.sh) добавляет worker, XPC, FFmpeg, bundles и Metal-ресурсы; `LOCALSCRIBE_SIGN_IDENTITY` задаёт подпись, по умолчанию ad-hoc.

## Архитектура и контракты

- Сохранять один последовательный worker. GUI и worker работают без `network.client`; сеть для загрузки есть только у XPC-сервиса. Он принимает ID профиля/индекс и возвращает файловый дескриптор, не получает архив, аудио или транскрипцию. Подробности — [Architecture](docs/Architecture.md).
- [WorkerSupervisor](Sources/LocalScribe/WorkerSupervisor.swift) и [Worker](Sources/LocalScribeWorker/Worker.swift) используют JSONL v1: команда в stdin, события в выделенном протокольном stdout; обычный stdout worker перенаправлен в stderr. EOF отменяет процесс и дочерние процессы. В протокольный канал писать только WorkerEvent; при отмене завершать всю сохранённую группу процессов и дожидаться обоих pipe readers даже после выхода лидера.
- Состояние UI/очереди изолировано `@MainActor` в AppModel и WorkerSupervisor; тяжёлые файловые операции выносятся из главного актора. Сохранять существующие границы actors и `@Sendable`, не отключать проверки concurrency ради сборки. Частые meter/elapsed/status публиковать через `ActivityIndicators`.
- Manifest меняет GUI; worker пишет артефакты в `runs`. В [Repository](Sources/LocalScribeCore/Repository.swift) manifest — источник истины, `index.json` — вспомогательный индекс; Core Data/SwiftData здесь нет.
- JSON сохранять через атомарный `Disk.write` с ISO 8601 датами из [Contracts](Sources/LocalScribeCore/Contracts.swift). Проверять schemaVersion, UUID каталога, длительность, ссылки и fingerprint перед использованием результатов. [ResultReading](Sources/LocalScribeCore/ResultReading.swift) читает результат целиком: повреждённый финальный JSON нельзя скрывать откатом к checkpoint или показывать частично.
- Сохранять разделение `activeRunId` и `pendingRunId`: неудачный повтор не уничтожает прошлый результат. Изменение поведения pipeline/prompt требует обновить `RunInfo.pipelineVersion` и fingerprint контрольных точек в [SummaryEngine](Sources/LocalScribeWorker/SummaryEngine.swift).
- «Продолжить» вызывает `RecordingRepository.resumeRun`: сохраняет pending run, проверяет его версию, исходник и закреплённый каталог через `ModelCatalog.pinned(to:)` с полными SHA файлов. Несовместимость не создаёт новое задание; для выбранных сейчас моделей предназначено «Обработать заново».
- Выбранные профили фиксируются в `RunInfo.modelIDs`; старые задания без поля используют исходные имена ролей. Не терять совместимость legacy fingerprint. Изменение выбора моделей не должно запускать ожидающие записи или менять manifests.

- Перед изменением фонового ASR читать [LiveCapture](docs/LiveCapture.md): `recording` относится к микрофону, `captureProcessing` — к обработке; ошибка модели не останавливает микрофон. Новая запись сохраняет FIFO и не прерывает текущий worker.
- В live ASR читать только закрытые CAF; связывать checkpoints с оригиналом через seal, SHA/PCM и непрерывное покрытие окон. Не удалять фрагменты до проверенного присоединения ASR и выхода worker.
- [ResultEditing](Sources/LocalScribeCore/ResultEditing.swift) сохраняет черновик полным новым run и только затем переключает activeRunId. Сохранять ID, таймкоды, участников и порядок оставшихся реплик; при изменении текста удалять старые word timings. Ручные итоги без evidence разрешены только для проверенной ручной версии; автоматические требуют основания.

## Локальные конвенции и ловушки

- UI и сообщения об ошибках преимущественно русские, идентификаторы английские; следовать соседнему коду с отступом 4 пробела. В [ContentView](Sources/LocalScribe/ContentView.swift) есть accessibility labels; String Catalogs, обязательных previews и UI snapshot-тестов не найдено.
- Ошибки для пользователя — `ScribeError.message`, показ — через единый [AppErrorHandler](Sources/LocalScribe/AppErrorHandler.swift), в том числе из настроек и редактора; неизвестные ошибки SDK worker заменяет нейтральным сообщением. SDK stderr непрерывно дренируется без сохранения: он может содержать текст разговора. Диагностика с текстом разрешена только явному техническому probe, см. [Architecture](docs/Architecture.md).
- Модели публикуются из `.partial` только после проверки размеров и SHA-256 всего комплекта. Для сетевого прогресса сохранять явный `URLSessionDownloadTask` и привязку callback к requestID: образцы — [Models](Sources/LocalScribeCore/Models.swift) и [ModelDownloadClient](Sources/LocalScribe/ModelDownloadClient.swift).
- При переключении записи очищать прежний результат сразу; асинхронный ответ применять только при совпадении UUID/signature, как в `AppModel.loadResult`.
- Текст и UTF-16 ranges для UI готовит [ResultPresentation](Sources/LocalScribe/ResultPresentation.swift) вне MainActor; `body` читает готовый результат. Кэш учитывает ревизию содержимого, метаданные, вкладку и формат, а не только fingerprint. При смене ключа сразу очищать текст/ссылки, устаревший async-ответ не применять. Читать [ResultRendering](docs/ResultRendering.md) перед изменением отображения/экспорта.
- Импорт в [ImportSource](Sources/LocalScribeCore/ImportSource.swift) закрепляет открытый дескриптор обычного файла до хэширования и создаёт независимую копию с повторной проверкой SHA; симлинк/подмена пути не должны менять исходник копирования.
- Callback микрофона использует ограниченный пул; запись файлов — на последовательной writerQueue. Восстановление включает только закрытые CAF-фрагменты. Уведомление AVAudioEngine само по себе не означает смену микрофона: читать [MicrophoneFix](docs/MicrophoneFix.md) перед изменением записи.
- Не сдвигать исходную шкалу времени при разделении ASR; не кластеризовать голоса независимо по частям. Перед изменением распознавания читать [ASRPrefixFix](docs/ASRPrefixFix.md): восстановление пропущенного начала использует реальный контекст без сдвига таймкодов. Итоги извлекаются отдельно по разделам/языкам с хронологическим контекстом и сохраняют evidenceSegmentIds и неопределённость, не выдумывают имена/сроки. Открытый вопрос закрывается только явным поздним ответом с проверенными ID/цитатой; молчание, частичный или неуверенный ответ сохраняют вопрос. Образцы — [Analysis](Sources/LocalScribeCore/Analysis.swift), [SummaryAnalysis](Sources/LocalScribeCore/SummaryAnalysis.swift), [Contracts](Sources/LocalScribeCore/Contracts.swift).
- Для диаризации сохранять отражение только неполного хвоста, реальные длины и отсечение интервалов по исходнику. Ошибки inference должны выходить наружу без публикации частичного результата. Канал между segmenter/embedder ограничен и не теряет блоки; ошибка/отмена будит обе стороны и дожидается дочерних задач. Читать [DiarizationTailFix](docs/DiarizationTailFix.md) и [DiarizationBackpressure](docs/DiarizationBackpressure.md) перед изменением SpeakerKit.
- Очистка аудио — только после выхода capture/worker и проверки SHA оригинала; JSON checkpoints, вход незавершённого live run и проверенные части установки сохранять. Подробности — [ResourceCleanup](docs/ResourceCleanup.md).
- Для MLX helper нужен `Contents/Helpers/mlx.metallib` рядом с worker и отдельная подпись: `Bundle.main` helper отличается от GUI. FFmpeg должен иметь minos 26.0; упаковщик проверяет это, см. [build_app.sh](scripts/build_app.sh).

## Тестирование

- [LocalScribeTests](Tests/LocalScribeTests/) проверяет Core, хранение, модели, live capture, редактирование, экспорт и итоги; [LocalScribeUITests](Tests/LocalScribeUITests/) — AppModel/supervisor/service и представления через XCTest, не полный XCUITest-прогон; [LocalScribeDiarizationTests](Tests/LocalScribeDiarizationTests/) — локальный SpeakerKit и worker.
- Файлы/модели создаются во временных UUID-каталогах и удаляются через `defer`; использовать `RecordingRepository(root:)`, `localSource` и замыкание `fetch`. Для AppModel — `startServices: false`, отдельные UserDefaults и `workerExecutable` с тестовым процессом. Образцы — [RunResumptionTests](Tests/LocalScribeTests/RunResumptionTests.swift), [ProcessingQueueTests](Tests/LocalScribeUITests/ProcessingQueueTests.swift).
- Два модельных теста диаризации явно пропускаются без `LOCALSCRIBE_DIARIZATION_FIXTURE_MODELS` / `LOCALSCRIBE_DIARIZATION_FIXTURE_WAV`; требования к локальному примеру — в [DiarizationTailFix](docs/DiarizationTailFix.md). Остальные проверки выполняются без весов, в том числе с fake predictors.
- При изменении хранения проверять сохранность внешних оригиналов/экспортов, старого active run и повреждённых элементов архива. При изменении моделей — отмену, SHA, прогресс, совместимость профилей и legacy-папок; при продолжении — неизменность pending/active run и checkpoints при отсутствующих/повреждённых моделях или смене ревизии.
- Перед изменением обработки читать [Architecture](docs/Architecture.md); перед модельным UI/установкой — [ModelManagement](docs/ModelManagement.md).
- Интеграционные проверки требуют собранных helper/tools, а для анализа — локальных весов и технического аудио. Настоящий путь worker получать командой выше: жёсткий `.build/out/Products/Release` из старых скриптов может отличаться.
- XCTest не подтверждает sandbox/TCC, работу микрофона или качество моделей. Для таких изменений читать [Acceptance](docs/Acceptance.md) и [MacAcceptance](docs/MacAcceptance.md); синтетическая речь не заменяет WER/DER и трёхчасовую приёмку на реальных встречах.

## Зависимости и границы изменений

- [Package.swift](Package.swift) фиксирует Argmax OSS 1.1.1 и MLX Swift LM 2.31.3; [Package.resolved](Package.resolved) отслеживается Git. При согласованном обновлении менять manifest и lockfile согласованно; обычная сборка использует `--force-resolved-versions`.
- **Всегда:** сохранять проверку исходного SHA, модельных хэшей и результатов перед публикацией: от них зависят возобновление и целостность архива. Проверять применимые вложенные AGENTS.md при их появлении.
- **Сначала уточнить, если это не входит в поручение:** изменение entitlements/Info.plist, подписи и схемы хранения — они затрагивают права, распространение и существующие данные. Явное поручение уже является разрешением.
- **Никогда:** не перегенерировать каталог моделей в обычной сборке и не ослаблять sandbox/сетевую изоляцию ради успешного запуска. Менять источник/профили в рамках соответствующей задачи, сохраняя проверку SHA.
- Не добавлять в коммиты кэши, веса и результаты прогонов: [.gitignore](.gitignore) исключает `.build`, `.swiftpm`, `Vendor`, `Assets`, `build`, `dist`, `TestResults`, логи. Основной код находится в Sources; [ThirdParty/SpeakerKit](ThirdParty/SpeakerKit/) отслеживается Git и участвует в сборке, Vendor содержит исключённые сторонние исходники. Обновление снимка SpeakerKit требует сверки `upstream.json`, трёх patch-файлов, лицензий и тестов по его README; не править `.build/checkouts`.
- В последних коммитах используются `feat:`/`fix:`/`docs:` с необязательной областью; обязательный формат коммитов, CI и PR-шаблон не найдены. Не выводить из этой истории новую политику.
