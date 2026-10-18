# AGENTS.md

## Проект и среда

LocalScribe — локальная запись, расшифровка и итоги встреч для Apple Silicon, macOS 26+.
SwiftPM-пакет без Xcode-проекта; GUI на SwiftUI/AppKit, анализ через WhisperKit, SpeakerKit и MLX.
Среда из [README](README.md): Xcode 27.0, Swift 6.4, Metal Toolchain 27A266a; Xcode/Swift подтверждены 18.10.2026.
[Package.swift](Package.swift) задаёт tools-version 6.1, минимум macOS 26.0 и Swift 5 language mode для трёх executable targets; Core и тесты используют режим Swift 6. Поддержка Linux не заявлена.

## Карта кода

- [LocalScribe](Sources/LocalScribe/) — UI, запись микрофона, очередь, управление manifest и запуск worker. Точка композиции — [AppModel](Sources/LocalScribe/AppModel.swift).
- [LocalScribeCore](Sources/LocalScribeCore/) — Codable/Sendable-контракты, файловое хранение, модели, аудио и экспорт; без зависимости от GUI и ML SDK.
- [LocalScribeWorker](Sources/LocalScribeWorker/) — этапы анализа; [Pipeline](Sources/LocalScribeWorker/Pipeline.swift) и [SummaryEngine](Sources/LocalScribeWorker/SummaryEngine.swift) — actors.
- [LocalScribeModelService](Sources/LocalScribeModelService/Service.swift) — XPC-загрузчик закреплённых файлов; [CWorkerIsolation](Sources/CWorkerIsolation/WorkerIsolation.c) — проверка/ограничение сети worker.
- [Resources](Resources/) — plist, entitlements, лицензии, каталог моделей. Сборка .app и ресурсов — в [scripts](scripts/).

## Команды

Выполнять из корня пакета на Mac с указанным Xcode/Metal Toolchain. Ниже статус проверки 18.10.2026; SwiftPM пишет служебные кэши вне репозитория.

| Задача | Точная команда | Статус |
| --- | --- | --- |
| Release executable targets | `swift build -c release -j 4 --force-resolved-versions` | запущено, ошибка — недоступен компилятор Metal; `xcrun metal --version` подтверждает отсутствие Metal Toolchain |
| Все XCTest | `swift test -c release -j 4 --force-resolved-versions` | запущено, ошибка на сборке MLX/Metal до выполнения тестов |
| Один тест | `swift test -c release -j 4 --force-resolved-versions --filter CoreTests/testAudioEngineNotificationDoesNotImplyMicrophoneChange` | запущено, ошибка — тот же сбой MLX/Metal, выполнено 0 тестов |
| Путь к executable | `swift build -c release --show-bin-path` | проверено — `.build/out/Products/Release` в этой среде |
| FFmpeg/ffprobe | `bash scripts/build_ffmpeg.sh` | (не проверено) — пересборка C-инструментов и возможная загрузка исходников не выполнялись |
| Упаковка .app | `bash scripts/build_app.sh` | (не проверено) — копирует ресурсы и подписывает .app, подпись в этой задаче не запускалась |

Источник SwiftPM-сборки — [build_app.sh](scripts/build_app.sh), тестов — [README](README.md) и [ModelManagement](docs/ModelManagement.md); фильтр взят из [CoreTests](Tests/LocalScribeTests/CoreTests.swift).
В репозитории не найдены команды линта/форматирования Swift и генерации Xcode-проекта. [format_checks.py](scripts/format_checks.py) проверяет аудиокодеки, а не стиль кода.
Генератор каталога `python3 scripts/lock_models.py` — (не проверено): обращается к сети и перезаписывает [models.lock.json](Resources/models.lock.json); для обычной сборки не нужен.
SwiftPM-сборка не создаёт готовую .app. [build_app.sh](scripts/build_app.sh) добавляет worker, XPC, FFmpeg, bundles и Metal-ресурсы; `LOCALSCRIBE_SIGN_IDENTITY` задаёт подпись, по умолчанию ad-hoc.

## Архитектура и контракты

- Сохранять один последовательный worker. GUI и worker работают без `network.client`; сеть для загрузки есть только у XPC-сервиса. Он принимает ID профиля/индекс и возвращает файловый дескриптор, не получает архив, аудио или транскрипцию. Подробности — [Architecture](docs/Architecture.md).
- [WorkerSupervisor](Sources/LocalScribe/WorkerSupervisor.swift) и [Worker](Sources/LocalScribeWorker/Worker.swift) используют JSONL v1: команда в stdin, события в stdout. EOF отменяет процесс и дочерние процессы. Произвольный `print` в протокольный stdout нарушит обмен.
- Состояние UI/очереди изолировано `@MainActor` в AppModel и WorkerSupervisor; тяжёлые файловые операции выносятся из главного актора. Сохранять существующие границы actors и `@Sendable`, не отключать проверки concurrency ради сборки.
- Manifest меняет GUI; worker пишет артефакты в `runs`. В [Repository](Sources/LocalScribeCore/Repository.swift) manifest — источник истины, `index.json` — вспомогательный индекс; Core Data/SwiftData здесь нет.
- JSON сохранять через атомарный `Disk.write` с ISO 8601 датами из [Contracts](Sources/LocalScribeCore/Contracts.swift). Проверять schemaVersion, UUID каталога, длительность, ссылки и fingerprint перед использованием результатов.
- Сохранять разделение `activeRunId` и `pendingRunId`: неудачный повтор не уничтожает прошлый результат. Изменения pipeline/prompt должны учитывать `RunInfo.pipelineVersion` и fingerprint контрольных точек в [SummaryEngine](Sources/LocalScribeWorker/SummaryEngine.swift).
- Выбранные профили фиксируются в `RunInfo.modelIDs`; старые задания без поля используют исходные имена ролей. Не терять совместимость legacy fingerprint. Изменение выбора моделей не должно запускать ожидающие записи или менять manifests.

## Локальные конвенции и ловушки

- UI и сообщения об ошибках преимущественно русские, идентификаторы английские; следовать соседнему коду с отступом 4 пробела. В [ContentView](Sources/LocalScribe/ContentView.swift) есть accessibility labels; String Catalogs, обязательных previews и UI snapshot-тестов не найдено.
- Ошибки для пользователя — `ScribeError.message`; неизвестные ошибки SDK worker заменяет нейтральным сообщением. SDK stderr непрерывно дренируется без сохранения: он может содержать текст разговора. Диагностика с текстом разрешена только явному техническому probe, см. [Architecture](docs/Architecture.md).
- Модели публикуются из `.partial` только после проверки размеров и SHA-256 всего комплекта. Для сетевого прогресса сохранять явный `URLSessionDownloadTask` и привязку callback к requestID: образцы — [Models](Sources/LocalScribeCore/Models.swift) и [ModelDownloadClient](Sources/LocalScribe/ModelDownloadClient.swift).
- При переключении записи очищать прежний результат сразу; асинхронный ответ применять только при совпадении UUID/signature, как в `AppModel.loadResult`.
- Callback микрофона использует ограниченный пул; запись файлов — на последовательной writerQueue. Восстановление включает только закрытые CAF-фрагменты. Уведомление AVAudioEngine само по себе не означает смену микрофона: читать [MicrophoneFix](docs/MicrophoneFix.md) перед изменением записи.
- Не сдвигать исходную шкалу времени при разделении ASR; не кластеризовать голоса независимо по частям. Итоги сохраняют evidenceSegmentIds и неопределённость, не выдумывают имена/сроки. Образцы — [Analysis](Sources/LocalScribeCore/Analysis.swift), [Contracts](Sources/LocalScribeCore/Contracts.swift).
- Для MLX helper нужен `Contents/Helpers/mlx.metallib` рядом с worker и отдельная подпись: `Bundle.main` helper отличается от GUI. FFmpeg должен иметь minos 26.0; упаковщик проверяет это, см. [build_app.sh](scripts/build_app.sh).

## Тестирование

- XCTest в [CoreTests](Tests/LocalScribeTests/CoreTests.swift) и [ModelTests](Tests/LocalScribeTests/ModelTests.swift) зависит от Core. Файлы/модели создаются в временных UUID-каталогах и удаляются через `defer`; использовать `RecordingRepository(root:)`, `localSource` и замыкание `fetch` для изоляции теста.
- При изменении хранения проверять сохранность внешних оригиналов/экспортов, старого active run и повреждённых элементов архива. При изменении моделей — отмену, SHA, прогресс, совместимость профилей и legacy-папок.
- Перед изменением обработки читать [Architecture](docs/Architecture.md); перед модельным UI/установкой — [ModelManagement](docs/ModelManagement.md).
- Интеграционные проверки требуют собранных helper/tools, а для анализа — локальных весов и технического аудио. Настоящий путь worker получать командой выше: жёсткий `.build/out/Products/Release` из старых скриптов может отличаться.
- XCTest не подтверждает sandbox/TCC, работу микрофона или качество моделей. Для таких изменений читать [Acceptance](docs/Acceptance.md) и [MacAcceptance](docs/MacAcceptance.md); синтетическая речь не заменяет WER/DER и трёхчасовую приёмку на реальных встречах.

## Зависимости и границы изменений

- [Package.swift](Package.swift) фиксирует Argmax OSS 1.1.1 и MLX Swift LM 2.31.3; [Package.resolved](Package.resolved) отслеживается Git. При согласованном обновлении менять manifest и lockfile согласованно; обычная сборка использует `--force-resolved-versions`.
- **Всегда:** сохранять проверку исходного SHA, модельных хэшей и результатов перед публикацией: от них зависят возобновление и целостность архива. Проверять применимые вложенные AGENTS.md при их появлении.
- **Сначала уточнить, если это не входит в поручение:** изменение entitlements/Info.plist, подписи и схемы хранения — они затрагивают права, распространение и существующие данные. Явное поручение уже является разрешением.
- **Никогда:** не перегенерировать каталог моделей в обычной сборке и не ослаблять sandbox/сетевую изоляцию ради успешного запуска. Менять источник/профили в рамках соответствующей задачи, сохраняя проверку SHA.
- Не добавлять в коммиты кэши, веса и результаты прогонов: [.gitignore](.gitignore) исключает `.build`, `.swiftpm`, `Vendor`, `Assets`, `build`, `dist`, `TestResults`, логи. Собственный код находится в Sources, а Vendor содержит сторонние исходники.
- В истории всего два коммита, один с `feat(models):`; обязательный формат коммитов, CI и PR-шаблон не найдены. Не выводить из этой истории новую политику.
