# Ревью проекта LocalScribe — 11 ноября 2026

Полное ревью репозитория `meetings_AI` (LocalScribe 2.11.0): все 312 отслеживаемых файлов (~42 тыс. строк Swift в Sources/Tests/ThirdParty, ~4 тыс. строк скриптов, 36 документов), плюс незакоммиченный WIP (`MicrophoneRecorder.swift`, `CaptureIngressTests.swift`, `docs/CapturePCM16.md`, untracked `docs/diagrams/`). Это четвёртое полное ревью; предыдущие — [10.10→18.10](ProjectReview-2026-10-18.md) (R01–R17, закрыты в основном к 24.10), [24.10](../ProjectReview-2026-10-24.md) (N01–N14, закрыты в [ProjectReviewFixes-2026-10-24.md](ProjectReviewFixes-2026-10-24.md)) и [09.11](../ProjectReview-2026-11-09.md) (большинство P1 закрыты коммитом `90a64a9` в тот же день).

Каждая находка ниже проверена чтением текущего кода; критичные P1/P2 перед публикацией перепроверены вручную по рабочему дереву. Код в ревью не изменялся; для проверки здоровья дерева запускалась только сборка: `swift build -c release -j 4 --force-resolved-versions` — **успех (92 с), включая незакоммиченный WIP**, но с 4 новыми предупреждениями компилятора (см. §4.2, п. 21) — утверждение ревью 09.11 «предупреждений нет» больше не выполняется.

## 1. Резюме

Проект по-прежнему образцового качества для локального ML-приложения: целостность данных (двойные SHA, атомарные записи, монотонные ревизии), сетевая изоляция worker, честная документация и 631 XCTest, проверяющие контракты, а не «зелёность». Коммит `90a64a9` добросовестно закрыл все шесть P1 ревью 09.11; новый код после него (диагностика копируемых ошибок, retry VibeVoice, menu bar, WIP-перезапуск движка) в основном добротный.

Куда сместился фокус проблем по сравнению с 09.11:

1. **Новые P1 найдены в стеке захвата звука** — самое неожиданное: смешанный режим молча отбрасывает системный звук, пока идёт переговоры с микрофоном (потеря начала встречи), а «приоритетный апгрейд» маршрута останавливает рабочий микрофон до подтверждения нового.
2. **WIP-диф содержит узкую гонку** в новом `waitForFirstMicrophonePacket` — стоит поправить до коммита (одна строка + тест).
3. **Свежая фича 2.11.0 (menu bar) не покрыта ни одним тестом** — при том что AGENTS.md прямо перечисляет её контракты.
4. **Структурные темы 09.11 не тронуты и подросли**: `AppModel` вырос с 1620 до 1847 строк; дублирование веток записей/схем (~250 строк на сайдбар, ~70 % копипаста координаторов) осталось главным источником расхождений — за две недели добавились новые (асимметрия `onDiscard`, разные стратегии delete/lock-резолвера).
5. **Диаризация по-прежнему держит весь 3-часовой PCM в памяти (~691 МБ + копия)** — единственная незакрытая ресурсная P2 из 09.11.

| Приоритет | Количество | Ключевые |
| --- | --- | --- |
| P1 | 7 + 1 переходящая | потеря начала записи в смешанном режиме; остановка записи при неудачном апгрейде маршрута; WIP-гонка; trap на дубликатах ID архива; menu bar без тестов; tar-блоб FFmpeg в исходном архиве; сетевая загрузка без SHA-пина; sleep-ассерты в критичных тестах (09.11) |
| P2 | ~30 | неатомарная замена модели; непрерывность live-предпросмотра; XPC без проверки клиента; SHA схемы после VLM; стартовая SHA-перепроверка всех весов; reload() на каждое предупреждение; нет CI |
| P3 | ~80 | см. разделы по модулям |

---

## 2. Статус плана ревью 09.11

### Закрыто (проверено по текущему дереву)

- SHA-валидация закреплённых Whisper/диаризации/итогов перед загрузкой в worker (`ASREngine.swift`, коммит `90a64a9`).
- Загрузка `NSItemProvider` стартует в drop-обработчике (`AppModel.importProviders`); `⌘⌫` на read-only транскрипте; guard'ы `deletingJobIDs` в `enqueueDiagram`; термогейт не тормозит реплей чекпойнтов; `capture-run.json` schemaVersion; метрики best-effort; tie-break сортировки по id; force-unwrap'ы (`Models.swift`, `Media.swift`, `Service.swift`, `Worker.swift`, `SummaryEngine.swift`).
- `build_app.sh` пересоздаёт `.app` с нуля (`rm -rf` на строке 21).
- Документация: `ASRBackendIntegration.md` теперь ведёт историю версий до актуальной `asr12`; README перечисляет все 26 профилей каталога (включая base, 2B, 122B-A10B, экспериментальные Qwen3-ASR/VibeVoice); `Package.swift` задаёт явные `.swiftLanguageMode(.v5)/(.v6)`.
- `docs/diagrams/` (7 PlantUML-схем + README, соответствуют реальным типам) закрывает давний пробел «нет архитектурной диаграммы» — **но каталог ещё не закоммичен**.

### Осталось открытым (переносится в текущие находки)

- **P1:** негативные ассерты после `sleep(300мс)` в `ProcessingQueueTests:172,198` — и появился третий экземпляр паттерна (`:1264`, sleep 200мс).
- **P2:** `ImportSource.copy` читает до EOF без ограничения по fstat-размеру (`ImportSource.swift:47-52`; параллельный `PinnedImageSource` в `DiagramRepository.swift:327-335` читает ровно `size`).
- **P2:** `DiagramCoordinator.delete` делает полный рескан архива на каждое удаление (`DiagramCoordinator.swift:114`).
- **P2:** диаризация читает весь WAV в `[Float]` (`Pipeline.swift:183`, ~691 МБ на 3 ч + копия в `MLXArray`).
- **P2:** `SpeakerEmbedderModel` не проверяет размер `embeddingsOutput` перед индексацией; `speakerDimensionForMasks()` возвращает 0 при отсутствии описания.
- **P2:** захардкоженные EOS-токены `[151645, 151643]` в `Qwen3ASR.swift:1029` (и дубль в `VibeVoiceModel.swift:124`); жёсткие `100/13` при `n_window ≠ 50`.
- **P2:** `media_pipeline_checks.py:5` / `media_failure_checks.py:6` — жёсткий путь воркера; `lock_models.py` не атомарен и слабее qwen-генератора; нет `lock_diagram_models.py`; нет verify.sh/CI; `ModelService-Info.plist` CFBundleVersion=1.
- **P2/P3:** недокументированные локальные правки QwenASR/VibeVoiceASR (без маркеров `// LocalScribe:` и patch-файлов, в отличие от SpeakerKit); отсутствие тестов `ModelDownloadClient`, `DiagramImageRegions.crops`, live-цикла `LiveTranscriber`; дублирование helpers тестов; `ASRContinuation.md:229` неверный путь теста; «Итог сессии 6» в 3 копиях; абсолютные ссылки в `ProjectReview-2026-10-18.md`; нет указателя docs/README.
- **P3:** `AppModel` god-object (теперь 1847 строк); дублирование сайдбаров (~64 %); `jobAdmission` растёт неограниченно; глубокое сравнение транскрипции на каждое нажатие клавиши (`ResultEditorView.swift:65`); занятие 3-кратного дублирования PCM-чтения в ASR-окнах; `translateEmbeddedArguments` на полных русских строках.

---

## 3. Новые находки P1

### P1-1. Смешанный режим отбрасывает системный звук до допуска — потеря начала встречи

**Где:** `Sources/LocalScribe/MicrophoneRecorder.swift:113-131`, `CaptureIngress.submit` (`:845-852`).

В `MicrophoneRecorder.start` process tap системного звука запускается первым (`:113-127`, намеренно — запрос разрешения), но допуск пакетов включается только в `ingress.start` (`:131`): `submit` гейтится по `admitted.contains(source)`, а `admitted` заполняется в `ingress.start`. Между ними выполняется `openInitialMicrophone` — до 4 с на кандидата плюс ожидание первого пакета. При падающих кандидатах микрофона **10+ секунд системного звука с начала встречи молча отбрасываются** — ровно в том сценарии (плохой микрофон), ради которого смешанный режим и существует. В mic-only-режиме проблемы нет.

**Как исправить:** фиксировать origin шкалы и допускать системный звук сразу при старте tap (источник уже пишется в независимые CAF через общий writer), а микрофон подключать к уже идущей шкале; `openInitialMicrophone` переносить после `ingress.start` либо admitting системный звук до неё. Приёмка: смешанная запись с намеренно падающим микрофоном — первый пакет системного звука попадает в CAF с таймкодом, близким к нажатию «Начать».

### P1-2. Приоритетный апгрейд маршрута останавливает рабочий микрофон до подтверждения нового

**Где:** `Sources/LocalScribe/MicrophoneRecorder.swift:557-566` (`routeMicrophone`).

При появлении более приоритетного входа текущий рабочий микрофон останавливается (`stopMicrophone()` + `beginMicrophoneRecovery(timeout: 9с)`) **до** того, как новый кандидат подтвердил первый пакет. Если апгрейд-кандидат не проходит, голос теряется на время перебора (рабочий маршрут лишь второй в очереди); если за 9 с не открылся ни один вход, в режиме «только микрофон» запись останавливается целиком (`recoveryTimeout` → `onStopNeeded`). Автоматическая оптимизация не должна ставить под угрозу уже идущую запись.

**Как исправить:** сначала открывать и подтверждать новый вход (параллельно или через второй engine/поток BT), лишь затем отпускать старый; либо как минимум не запускать `beginMicrophoneRecovery`-таймер, пока жив рабочий маршрут, и не останавливать запись при живом системном звуке. Приёмка: рабочий микрофон + появление приоритетного нерабочего входа — шкала голоса непрерывна, запись не останавливается.

### P1-3. WIP: гонка между сбросом и перезапуском в `waitForFirstMicrophonePacket`

**Где:** `Sources/LocalScribe/MicrophoneRecorder.swift:262-266` (wait-цикл), `:714-718` (`clearPendingMicrophonePacket`), `:845-848` (`submit`).

В незакоммиченном диффе между `clearPendingMicrophonePacket(token)` и `restart()` поздний in-flight callback уже остановленного движка успевает снова записать `microphoneCallbackHostTime` (строка 848, аудио-поток). Wait-цикл после перезапуска увидит «пакет есть» и допустит микрофон по мёртвому пакету — инвариант «новый пакет после перезапуска» (заявленный в обновлённом `docs/CapturePCM16.md`) нарушается. Спасает только 3-секундный stall-монитор: короткий провал звука и лишнее предупреждение.

**Как исправить до коммита:** сбрасывать хост-время под той же `gate` внутри перезапуска (например, метод `invalidatePendingMicrophonePacket`, выполняющий clear+flag атомарно с постановкой restart-номера), либо добавить к хост-времени эпоху рестарта. Дополнить новый тест проверкой «пакет между clear и restart не допускается».

### P1-4. `Dictionary(uniqueKeysWithValues:)` в didSet — краш GUI на архиве с дублирующимися ID

**Где:** `Sources/LocalScribe/AppModel.swift:49` (recordings) и `:26` (diagrams).

Снимок архива с двумя каталогами, чьи manifest несут один id (ручное копирование каталога записи, частичная порча), валит приложение trap'ом на первом же `applySnapshot` — вместо показа диагностики повреждённых элементов, как требует контракт AGENTS.md («повреждённый каталог … не заменяется пустым», ошибки через AppErrorHandler).

**Как исправить:** `Dictionary(_:uniquingKeysWith:)` с журналированием повтора id и репортом через существующую диагностику повреждённых записей. Приёмка: архив с дубликатом id открывается, приложение живо, дубликат виден в диагностике.

### P1-5. Menu bar (фича 2.11.0) не покрыт ни одним тестом

**Где:** коммит `1dbc5fd`; `Sources/LocalScribe/LocalScribeApp.swift:44-70`; в Tests/ нет упоминаний MenuBar/applicationShouldTerminate (проверено поиском).

AGENTS.md прямо требует: запуск записи и quit из MenuBarExtra при закрытом главном окне, общий допуск `canStartRecording`, один и тот же AppModel у делегата, `⌘Q` через `applicationShouldTerminate → shutdown`. Единственный добавленный тест проверяет лишь `canStartRecording`. Регрессия в свежей фиче (например, рассинхрон делегата или двойной запуск записи) пройдёт незамеченной.

**Как исправить:** юнит-тесты `LocalScribeMain`/делегата: старт из menu bar при закрытом окне (фикстура WorkerSupervisor как в ProcessingQueueTests), quit сохраняет индекс и завершает запись, делегат получает AppModel окна.

### P1-6. В «исходный» архив попадает 11-МБ сетевой tarball FFmpeg

**Где:** `scripts/package_source.sh:6`; тест `scripts/tests/test_package_source.py:21`.

Exclude указывает только `Vendor/ffmpeg-8.0.1`, но не `Vendor/ffmpeg-8.0.1.tar.xz` — bsdtar не матчит имя каталога против файла (поведение проверено на изолированном примере). Загруженный из сети блоб уезжает в архив, который README описывает как архив исходников без сборочных кэшей; состав и размер архива зависят от того, запускался ли `build_ffmpeg.sh`.

**Как исправить:** `--exclude=Vendor` целиком (каталог в .gitignore) + фикстуры `Vendor/*` в тест состава архива.

### P1-7. Единственная сетевая загрузка репозитория без закреплённого SHA

**Где:** `scripts/external_codec_checks.py:10`.

Фикстуры samples.ffmpeg.org скачиваются `urllib` без SHA-256 и пишутся сразу в финальный `Assets/format-fixtures`, минуя temp+rename. Эти файлы затем декодируются bundled ffmpeg (surface парсера) — т. е. это единственная непроверенная сетевая загрузка в проекте, где все остальные пути (FFmpeg-архив, модели, генераторы каталога) SHA закрепляют.

**Как исправить:** закрепить SHA-256 каждого образца в скрипте, качать во временный файл и переименовывать после проверки (паттерн `build_ffmpeg.sh:17-18`); заодно закрывает оборванные «полу-фикстуры», которые следующий запуск пропускает по `if not target.exists()`.

---

## 4. Findings по модулям

Приоритеты: **P2** — существенная ошибка корректности/ресурсов/поведения; **P3** — полировка и оптимизация. Формат: файл:строка · проблема · почему · как исправить.

### 4.1 Sources/LocalScribeCore

**P2**

1. `ModelDirectory.swift:170-172` · публикация модели не атомарна: старый final удаляется (`remove(finalName)`) до `renameatx_np(..., RENAME_EXCL)` · сбой/вылет в этом окне оставляет пользователя без рабочей модели (останется только `.partial`; откат вернёт partial, но не прошлый рабочий комплект — гигабайты перекачки) · публиковать через staging: переименовать старый final в резервное имя (или `RENAME_SWAP`), поставить новый, удалить резерв.
2. `ResultReading.swift:96` · live-предпросмотр проверяет только уникальность индексов частей, но не непрерывность `0..<count` (offline-ветка `:60` проверяет `sorted == Array(0..<count)`) · потерянная средняя live-часть молча склеивается в таймлайн с дырой — нарушает принцип «не показывать частично» · добавить проверку непрерывности либо явный флаг дыры с предупреждением.
3. `ModelLibrary.swift:13-18` (+ `AppModel.swift:352`) · при каждом запуске приложения выполняется полный SHA-256 всех файлов всех установленных профилей · десятки ГБ хэшируются до готовности `modelLibrary` (гейт готовности очереди) — заметная стартовая задержка и износ диска; полная перепроверка и так выполняется в `pinned(to:).validate` перед каждым run/resume · быстрый допуск по size+mtime, полная верификация перед использованием.
4. `RecordingCoordinator.swift:77-93,187-226,251-282` vs `DiagramCoordinator.swift:214-243,256-315` · ~70 % структурного копипаста транзакционных механик (replace/publish/pruneDeletedMembership/reserveDestination/editGroups/prepare+finishGroupDeletion); дублирование уже дало дрейф (разные стратегии delete и lock-резолвера) · следующий фикс только в одной ветке станет багом · generic-слой по протоколу «манифест+репозиторий» без смешивания статусов и корней.
5. `DiagramCoordinator.swift:114` · каждое удаление схем (включая одиночное из карточки) завершается полным ресканом `replace(readListing())`; аудио-ветка фильтрует in-memory · O(n) дисковых чтений на каждый delete · фильтровать in-memory, rescan только в catch-ветви.
6. `ImportSource.swift:47-52` (переходящая с 09.11) · копирование читает до EOF без ограничения по fstat-размеру, тогда как `PinnedImageSource` читает ровно `size` и отклоняет растущий файл · дописываемый между hash и copy файл даёт ложный поздний сбой и неограниченное чтение · перенести паттерн `while count < size`; см. также п. 13 (дублирование pinned-source).

**P3**

7. `Repository.swift:67` · дубликаты при импорте ищутся только по in-memory снимку — повреждённые записи архива не участвуют, тот же файл импортируется повторно · сверять по дисковому списку/хэш-индексу.
8. `Contracts.swift:15-18` · `Disk.read` без ограничения размера (для схем result.json ограничен — `DiagramRepository.swift:243`, для manifest/run/transcript/checkpoint — нет) · раздутый повреждённый файл целиком уедет в память · лимит размера при чтении артефактов.
9. `Contracts.swift:203-206` · `Summary.validate` — O(F×E×S) с `localizedCaseInsensitiveContains` на каждый finding (переходящая с 09.11) · один словарь `id → Segment` на проверку.
10. `Contracts.swift:138` · `Transcript.validate` допускает `durationMs == 0` · сузить до `1...max`.
11. `Media.swift:23+63` · `fileHandleForWriting` закрывается дважды (явно и в defer) · двойной close — хрупко; закрывать один раз в defer.
12. `Media.swift:200` · `assembleCapture` принимает любые `*.caf` (кроме `.partial.`) и сортирует лексикографически · посторонний caf молча вклеивается в оригинал; строгая проверка имён `part-%06d.caf` уже есть в `CaptureIntegrity.fragments` · применить ту же проверку.
13. `ImportSource.swift:10-59` vs `DiagramRepository.swift:272-343` · `PinnedImageSource` — копипаст `ImportSource` с разошедшейся семантикой границы чтения · security-критичная механика в двух копиях · один параметризованный pinned-source с явной политикой границы.
14. `Export.swift:20-23` vs `DiagramExport.swift:62-69` · два разных markdown-эскейпера для одного класса недоверенного текста (разный набор экранируемых символов) · один общий эскейпер с объединённым покрытием.
15. `DiagramExport.swift:80` · `Dictionary(uniqueKeysWithValues:)` для алиасов — трэп на дубликатах id при невалидированном `DiagramResult` (соседний `text()` использует `uniquingKeysWith`) · унифицировать.
16. `RecordingGroups.swift:91-105 vs 107-123` · `loadGroups`/`saveGroups` — точные копии `loadCatalog`/`writeCatalog` · делегировать нейтральным функциям.
17. `Localization.swift:62-66` · битый EN-каталог молча включает русский интерфейс (три `try?`) · хотя бы os_log причины деградации.
18. `Localization.swift:157-181` · `translateEmbeddedArguments` хардкодит полные русские тексты ключей · правка формулировки молча отваливает вложенный перевод · стабильные ключи-идентификаторы.
19. `Models.swift:189-195` · скачанный файл переносится в `NSTemporaryDirectory` до потребления · вылет между колбэком и потреблением оставляет мусорный multi-GB файл; чистить осиротевшие `localscribe-model-*` при старте установщика.
20. `Analysis.swift:52-58` · слияние соседних слов допускает отрицательный зазор (перекрывающийся вход склеивается в перепутанном порядке) · не сливать при `word.startMs < last.startMs`.
21. `SummaryAnalysis.swift:85-88` · «Одна реплика превышает контекст» выдаётся и для пустых сегментов (`count <= 0`) · отдельная ошибка для неположительных счётчиков.
22. `DiagramCoordinator.swift:168-176` · `cancel(onlyPending: false)` может перевести `.completed` в `.cancelled` на уровне ядра; защита живёт только на вызывающих · запретить стирание успешного терминального статуса в координаторе.

### 4.2 Sources/LocalScribe — логика (AppModel, очередь, supervisor)

**P2**

1. `AppModel.swift:1017-1031` (переходящая, актуальные строки) · недетерминированная перезапись `lastError` после отмены живого задания: продолжения `stopRecording` и catch `processQueue` конкурируют, generic «Обработка прервана…» может затереть конкретную причину («Нет сохранённого звука…») · в catch не писать `lastError`/state при `ownsJob == false`.
2. `AppModel.swift:552` · во внешнем catch `enqueueImport` не вызывается `onDiscard()` (внутренний guard вызывает) — при броске `importQueue.enqueue` NSItemProvider продолжит загрузку, continuation повиснет; в параллельной диаграммной реализации `onDiscard` в catch есть · добавить вызов.
3. `AppModel.swift:1047, 1169-1174` · полный `reload()` выполняется после каждого этапа каждого задания и на каждое событие warning worker'а · на больших архивах очередь сериализуется с O(n)-перестройкой поискового корпуса; частые предупреждения умножают эффект · дедуплицировать warnings, батчить reload.
4. `DiagramWorkspaceModel.swift:110-116` · `loadPreview` запускает `Task.detached` и не сохраняет/не отменяет задачу · быстрое переключение выделения декодирует несколько больших PNG параллельно (пики памяти) · хранить Task и отменять предыдущий.
5. `AppModel.swift:1724-1725` · `while savingResult/finalizingRecording { sleep 50ms }` в shutdown без таймаута · зависшая операция на archive-actor — приложение никогда не завершится · верхняя граница ожидания с репортом.

**P3**

6. `AppModel.swift:47-53 + 18/30` (переходящая) · двойная перестройка поискового корпуса на каждый снимок (два didSet) · единая точка обновления в applySnapshot.
7. `WorkerSupervisor.swift:201` · безусловный `Task.sleep(300мс)` в `cancel()` даже по мёртвому процессу · +300 мс на каждый упавший этап · ранний выход при завершённых readers.
8. `AppModel.swift:1497` · условие авто-постановки `jobAdmission[...] == nil` всегда истинно (id новые, ключи не чистятся) · мёртвая проверка; чистить `jobAdmission` вместе с `deletingJobIDs` (переходящая тема неограниченного роста).
9. `AppModel.swift:1597-1598` · `withDiagramDeletion` молча превращается в no-op при идущем удалении — UI получает «успех» · репортить ошибку.
10. `AppModel.swift:1104` · `JobState(rawValue: stage.rawValue)!` — force unwrap в рантайм-пути · guard с понятной ошибкой.
11. `AppModel.swift:1204,1272,1288,1581` · busy-wait `while busy { sleep 50ms }` на MainActor в четырёх местах · сигнальное завершение (CheckedContinuation).
12. `AppModel.swift:992` · `defer { status = "" }` в processQueue может затереть параллельный служебный статус («Скопировано») · чистить только свой статус.
13. `AppModel.swift:182` · `selected` — линейный поиск по массиву при готовом `recordingsByID` · O(n) в горячем пути UI.
14. `AppModel.swift:1305-1307 + 911-913` · `sidebarRecordingOrder` пересобирается на каждый клик, `queuePosition` — O(n) на строку → O(n·q) на рендер · кэшировать по ревизии снимка.
15. `AppModel.swift` (ветки recording/diagram: cancel/enqueue/удаление/pause) · ~200 строк систематического дублирования, уже расходятся (onDiscard, guard'ы) · обобщённый хелпер над (archive, job).
16. `AppModel.swift:467-479` · при броске `selectModels` независимые флаги настроек не применяются и теряются · применять флаги отдельно от выбора моделей.
17. `SettingsWindow.swift:117-121` · `windowDidResize` пишет UserDefaults на каждый тик ресайза · дебаунс/`windowDidEndLiveResize`.
18. `AppErrorHandler.swift:94-98` · `reports` растёт неограниченно за сессию (каждое предупреждение со стеком) · ограничить очередь с дедупликацией повторов.
19. `AppInfo.swift:4-9` · хардкод-фолбэки версии «2.11.0»/«21» — рассинхронизируются при выпуске · убрать фолбэк или проверять тестом скриптов.
20. `AppModel.swift:236,344,781,995 и др.` · часть статус-строк идёт мимо L10n, `status = event.message` (`:1165`) показывает сообщение worker без `L10n.message` · при английском интерфейсе служебные статусы останутся русскими · прогнать через L10n.
21. `AppModel.swift:515:53, 991:19, 991:48`, `DiagramWorkspaceModel.swift:297:9` · 4 предупреждения компилятора в релизной сборке (неиспользуемые `archive`/`repository`/`catalog` и лишний `try` — регрессия коммитов 09–10.11) · нулевая полировка, но ломает инвариант «сборка без предупреждений» и скрывает будущие важные warning'и в шуме · убрать мёртвые binding'и и `try`.

### 4.3 Sources/LocalScribe — захват звука и представления

(Кроме P1-1…P1-3 из раздела 3.)

**P2**

1. `BluetoothMicrophoneCapture.swift:39-47,60-64` + `MicrophoneRecorder.swift:357-365` · callback BT отбрасывает пакеты при `rate == 0` (между `AudioDeviceStart` и чтением VirtualFormat), смена 24/48 кГц подхватывается только через debounce 100 мс · на переключениях AirPods пакеты маркируются устаревшей частотой — искажение таймшкалы ~100+ мс, потеря первого куска речи · сверять фактическую частоту потока в callback и буферизовать/корректировать.
2. `TimedCaptureWriter.swift:119-135,160-176` · единственная защита от гигантского скачка hostTime (глюк драйвера/агрегата) — 3-часовой лимит: `render→drain` молча запишет ~1 ГБ тишины одним заходом · writer зависает на записи, диск заполняется · ограничить максимально допустимый gap (обрывать сегмент, публиковать предупреждение).
3. `MicrophoneDevices.swift:154-165` · полный синхронный HAL-снапшот (десятки `AudioObjectGetPropertyData`) на MainActor на каждое срабатывание listener; BT-переговоры генерируют шторм событий · подёргивания UI · коалесцировать/выносить снапшот с MainActor.
4. `AppModel.swift:696-703` · manifest записи публикуется только после `capture.start`, который уже пишет CAF-фрагменты · крах в этом окне оставляет осиротевший каталог записи без manifest — недоступен для восстановления и не чистится · создавать manifest (state=recording) до старта захвата или чистить сироты при загрузке архива.
5. `MicrophoneCaptureWriter.swift:6-104` · класс не инстанцируется в проде (запись идёт через `TimedCaptureWriter`); из файла используются только константы и `peak` · две параллельные реализации PCM16-писателя, часть тестов проверяет не продовый путь · удалить мёртвый класс, перенести константы.
6. `RecordingGroupsSidebar.swift:184-344` vs `DiagramGroupsSidebar.swift:56-326` (переходящая) · DropArea/GroupOrderDrop/InsertionLine/GroupHeader — построчный дубль ~250+ строк, различия только типами переноса · обобщить через generic по UTType и протоколу архивной модели (shared-примитивы уже есть).
7. `MicrophoneRecorder.swift:135-139,215-219,613-656` · нет deinit-страховки: при освобождении без `stop()` утекают changeObserver, activity (ProcessInfo) и 3-часовой `durationLimit`-таск · добавить `deinit` с отменой задач и `endActivity` как защиту от будущих правок.
8. `RecordingGroupsSidebar.swift:400-409`, `DiagramGroupsSidebar.swift:353-358,376-386` · Enter в окнах удаления групп/схем подтверждает без перепроверки доступности в обработчике — нарушение собственной конвенции AGENTS.md (образец — `DeleteSidebarRecordingsView:373-379`) · добавить guard.

**P3**

9. `MicrophoneRecorder.swift:687,760,907` · `lastSystemSignal` не инициализируется в `ingress.start` — «Системный звук пока не поступать» мигает на первом тике · присвоить `.now()` рядом с `lastLoudSignal`.
10. `ContentView.swift:122,128`, `MicrophoneRecorder.swift:754`, `TimedCaptureWriter.swift:162` · force-cast `as! NSTextView` и force-unwrap каналов буферов в рантайм-путях (безопасны по инвариантам, но хрупки к изменениям иерархии) · guard-цепочки.
11. `DiagramWorkspaceModel.swift:110-116` · `NSImage(contentsOf:)` в `Task.detached` — формально UB по потокобезопасности · читать Data/CGImageSource в фоне, NSImage на MainActor.
12. `ContentView.swift:127-139` · `updateNSView` сравнивает весь `RenderedExport` (длинные строки) на каждый рендер · лёгкий ключ (id+revision+part) вместо полного Equatable.
13. `RecordingDetailColumn.swift:91` · фиксированная ширина segmented picker (270/410) — при английской локализации подписи могут обрезаться · intrinsic sizing.
14. `MicrophoneRecorder.swift:301-303` · подсказка размера буфера тапа `sampleRate/5` без верхнего предела (384 кГц → 76 800 фреймов) · зажать в 512...8192.
15. `MicrophoneRecorder.swift:840-843 vs 859` · проверка переполнения `hostTime + duration` есть только для `count > capacity` · вынести в одну проверенную функцию.

### 4.4 Sources/LocalScribeWorker + ModelService + CWorkerIsolation

**P2**

1. `Pipeline.swift:183` (переходящая) · диаризация читает весь PCM в память (~691 МБ на 3 ч + копия в `MLXArray`) — пик RSS ~1,4 ГБ поверх Metal-бюджета модели; этап не чекпойнтится, OOM обнуляет работу · стримить чанками в SpeakerKit (bounded-канал в снимке уже есть) или как минимум заложить объём PCM в `ModelHardware.modelBudgetBytes`.
2. `DiagramEngine.swift:164-179` · SHA изображения сверяется до, но не после генерации VLM — файл мог измениться за минуты распознавания, результат опубликуется под старым fingerprint · повторить `Disk.hash(original) == info.sourceHash` перед `Disk.write(result)` (по образцу live-аудио, `LiveTranscriber.swift:75`).
3. `Sources/LocalScribeModelService/Service.swift:63-69` · XPC-слушатель принимает любое соединение без проверки auditToken/подписи клиента · единственный сетевой компонент приложения: любой процесс сессии может заставить сервис качать гигабайты из закреплённого каталога · сверять `connection.auditToken` с приложением (SecCode) в `shouldAcceptNewConnection`.
4. `SummaryEngine.swift:238-239` · одна непрошедшая валидацию amendment-правка бросает throw и валит всю задачу итогов — готовые проверенные пункты не публикуются из-за одного дефекта · для «amended» при провале инвариантов помечать исходный пункт `uncertain=true` + warning (мягкая деградация для «cancelled» уже есть на `:230-231`).
5. `LiveTranscriber.swift:63-66` · thermal-ожидание (sleep 2 с, continue) не ограничено по времени и срабатывает для sealed-потока · финализация завершённой записи может стоять неограниченно при затяжном serious-thermal · предел ожидания для sealed-хвоста.

**P3**

6. `Worker.swift:44,46` · `dup(STDOUT_FILENO)` без проверки -1, `fcntl` проигнорирован · при исчерпании fd протокольный канал молчит, родитель теряет все события · проверять и падать с кодом 73.
7. `Worker.swift:66-114` · `runCommand`/`runDiagram` — почти идентичные ~20 строк (started, метрики rusage, безопасная ошибка) · общий helper запуска этапа.
8. `Pipeline.swift:54` + `LiveTranscriber.swift:19-20` (переходящая) · models.lock.json читается и `catalog.pinned(to:)` вычисляется дважды в live-пути · передать параметром.
9. `Pipeline.swift:54-55` vs `DiagramEngine.swift:270-279` (переходящая) · два разных резолвера models.lock.json (аудио требует toolsPath, схемы — три кандидата) · один общий резолвер.
10. `Pipeline.swift:25` · повторная проверка `UUID(uuidString:)` (уже `:17`) · удалить дубль.
11. `WhisperASREngine.swift:72-76`, `QwenASREngine.swift:62-68` (переходящая) · двойное чтение/декод PCM на каждое окно (planning + рабочее) · читать один диапазон с контекстом и вырезать срезы.
12. `WhisperASREngine.swift:77-79` · energy тишины считается по всему чтению включая контекст — громкий контекст при тихом core даёт ложное «несущественное окно» · считать только по core.
13. `VibeVoiceASREngine.swift:39-47` · нет метрик окон и bypass цифровой тишины (у Whisper/Qwen есть) · минута тишины уходит полноценным вызовом на 8192 токенов · добавить `metrics?.window(...)` и `allSatisfy { $0 == 0 }`.
14. `SummaryEngine.swift:386` · greedy-повтор незавершённого ответа с тем же контентом почти наверняка обрывается там же · на unfinished сразу throw или суффикс-инструкция «продолжи с места обрыва».
15. `DiagramEngine.swift:224` · при региональном распознавании итоговый kind жёстко `.graph`, хотя регионы могут быть state · выводить kind из регионов (разнобой → `.graph`).
16. `DiagramEngine.swift:493-500` · `WireEdge.direction` — строгий enum: одно нестандартное значение роняет decode всего ответа и запускает корректирующий повтор на 4000 токенов · декодировать String, неизвестные → `.none` + uncertain.
17. `DiagramEngine.swift:170-171` · «Распознаваем…» эмитится до ленивой загрузки контейнера VLM · эмитить прогресс загрузки из распознавателя.
18. `CWorkerIsolation/WorkerIsolation.c:12` · блокирующий `connect()` к 127.0.0.1:9 — при firewall-drop старт воркера висит до TCP-таймаута (~75 с) · `SO_RTIMEO`/неблокирующий сокет; заодно добавить IPv6-пробу (сейчас только IPv4).
19. `Service.swift:14-21` · локальный handle временного файла живёт до следующего `clean()` после успешной передачи · закрывать сразу после reply.
20. `ASRMetrics.swift:148-152` · атомарная запись metrics-asr.json после каждого события — сотни fsync на 3 ч · сохранять по таймеру/фазам.
21. `LiveTranscriber.swift:48` · прогресс-событие каждую секунду ожидания — тысячи одинаковых JSONL-строк за длинный простой · не чаще раза в 10-30 с или при изменении.
22. Движки (`QwenASREngine.swift:26`, `VibeVoiceASREngine.swift:21`, `SummaryEngine.swift:41`, `DiagramEngine.swift:32`) берут `ModelHardware.current` напрямую при инъектированном `hardware` в Pipeline · прокидывать в конструкторы.
23. `QwenASREngine.swift:95` · пользователю показываются сырые миллисекунды («в интервале 7200000–7235000 мс»); Whisper использует `timecode(...)` · обернуть.

### 4.5 ThirdParty (SpeakerKit, QwenASR, VibeVoiceASR)

Математика адаптеров проверена против upstream (mlx-audio-swift): мел-фронтенд Qwen3, нормализация VibeVoice, чанковый энкодер, оконная логика — соответствуют референсам; снимок SpeakerKit сверен с `upstream.json` по SHA (18/18 файлов, расхождения ровно на 4 пропатченных + новый `DiarizationChannel.swift`). Сценариев P0/P1 (тихая порча результата, падение inference) не найдено.

**P2**

1. `ThirdParty/QwenASR/Sources/Qwen3ASR.swift:1052-1111,1187-1300`, `VibeVoiceModel.swift:46,124-138` · локальные правки (chunked prefill, repetition backstop, in-memory BPE, 300-с лимит, throw-без-EOS) не имеют ни маркеров `// LocalScribe:`, ни patch-файлов; `upstream.json` хранит только SHA upstream-версий · при обновлении снимка невозможно механически отличить локальную дельту от upstream — риск потерять критичные исправления (как минимум «ошибка вместо частичного текста») · пометить блоки маркерами (как в SpeakerKit) или зафиксировать SHA/patch-файлы.
2. `SpeakerEmbedderModel.swift:234-238` · явная обнуляющая заливка `chunkSpeakerMasks` через NSNumber-subscript — MLMultiArray уже нулевая; сотни тысяч boxing-записей на каждый 30-с блок (миллионы на 3 ч) в hot path · удалить цикл.
3. `SpeakerEmbedderModel.swift:284-305` (переходящая) · размер `embeddingsOutput` не проверяется перед `embeddingsOutput[chunkSpeakerIdx]`; `speakerDimensionForMasks()` возвращает 0 без описания speaker_masks · крах вместо `SpeakerKitError.invalidModelOutput` · guard размерностей против `windowsCount*speakersCount`.
4. `Qwen3ForcedAligner.swift:295-315,251-291` (переходящая) · `preprocessAudio` и сплайс фичей побайтно дублируют `Qwen3ASR` — frontend ASR и aligner обязаны быть идентичны · следующая правка мел/обрезки в одной копии молча рассинхронизирует выравнивание с транскрипцией · общий хелпер модуля.
5. `Qwen3ASR.swift:51-60` (переходящая) · `getFeatExtractOutputLengths` жёстко кодирует константы, связанные с `n_window = 50`; при расхождении — тихая деградация качества без ошибки · параметризовать или проверять `nWindow == 50` при загрузке.
6. SpeakerKit (процесс, переходящая) · цепочка патчей не проверяется автоматически против снимка · тест/скрипт сверки SHA применённой цепочки.

**P3**

7. `Qwen3ASR.swift:1301-1351`, `Qwen3ForcedAligner.swift:420-462`, `VibeVoiceModel.swift:158-193` · три копии `fromModelDirectory` · общий загрузчик весов.
8. `DSP.swift:218-221,199` · при `paddedLen < nFft` `asStrided` читает за границей; пустое аудио — крэш слайса · guard коротких входов.
9. `DSP.swift:28-45,64-76` · неиспользуемые `hammingWindow`/`powerToDB`, дефолты не-Whisper · удалить/перевернуть дефолты.
10. `DSP.swift:107-127` · в slaney-конверсии участвует `fMin` (librosa использует 0) — при ненулевом fMin тихое расхождение · исключить из скейла.
11. `DSP.swift:249,262-268` · окно Ханна и mel-filterbank пересоздаются на каждый вызов · кэшировать по параметрам.
12. `Qwen3ASR.swift:1082-1084,1120-1138` (переходящая) · `temperature` не влияет на greedy-результат · убрать или реализовать сэмплирование.
13. `Qwen3ASR.swift:826-848` · при расхождении `numAudioTokens` и `audioFeatures.dim(0)` сплайс падает runtime-ошибкой MLX · явный guard с диагностикой.
14. `Qwen3ASR.swift:1297-1298`, `VibeVoiceModel.swift:186-187` (переходящая) · `as! [NSString: Any]` на tokenizer-JSON — краш вместо ошибки · `as?` + throw.
15. `Qwen3ASR.swift:278-293,471-548,946-962`, `Qwen2.swift:227-236` · мёртвый код (`createBlockAttentionMask`, `encodeSingleWindow`, `mergeLanguages`, `Qwen2Model.sanitize`) · удалить при следующей синхронизации.
16. `Qwen2.swift:222` · `model.embedTokens!.asLinear(out)` — force unwrap в пути inference · guard.
17. `VibeVoiceModel.swift:45-56` · `[1, N]`-вход интерпретируется как 1 отсчёт × N каналов — тихий мусор вместо ошибки · валидация формы.
18. `VibeVoiceModel.swift:31-32,196-202` (переходящая) · мёртвые `speechStartId`/`speechEndId` · удалить/задокументировать.
19. `ClusteringAlgorithms.swift:441-449` · Lance-Williams `sqrt` без защиты от малого отрицательного — NaN заражает кластеризацию · `max(0, …)`.
20. `PyannoteDiarizer.swift:303-311` · `Int(30 / windowLength)` усекает — хвостовые фреймы тихо выпадают при неделимости · валидировать делимость.
21. `SpeakerSegmenterModel.swift:255` · reflectTail дублирует граничный сэмпл в шве · `dropLast().reversed()`.
22. `SpeakerSegmenterModel.swift:162` · `chunkStride` усекает секунды — безопасно только для закреплённой модели · проверять целочисленность в validateGeometry.
23. `SpeakerEmbedderModel.swift:262` · `activeSpeakersIndex.contains` внутри покадрового цикла — O(speakers) на фрейм · вынести на уровень окна/Set.
24. `PyannoteModelManager.swift:47` · `models` — обычный var на @unchecked Sendable-классе · @Protected, как model в моделях.
25. `Qwen3ForcedAligner.swift:172-174` (переходящая) · пустые секции MARK после удаления LIS · убрать; туда же — `Qwen3ASR.swift:12` неиспользуемый `import Hub`, `:569` неиспользуемый `layerIdx`.
26. EOS-наборы `[151645,151643]` дублированы в двух адаптерах (переходящая) · общая константа или `tokenizer.eosTokenId`.

### 4.6 Тесты

Сильное: реальные процессы-фикстуры worker, детерминированные gate-акторы, ноябрьские фичи покрыты (VibeVoice retry/recursion полностью; диагностика ошибок с двух сторон, включая краш-тест SIGTRAP `ProcessingQueueTests:858`; WIP `waitForFirstMicrophonePacket` — рестарт и таймаут).

**P2**

1. `ImportQueueTests.swift:44` · helper создаёт `UserDefaults(suiteName: UUID())` без `removePersistentDomain` — единственный файл из 15 · ~6 leaked-плистов за прогон оседают в `~/Library/Preferences` навсегда · teardown-блок по образцу `RecordingGroupIntegrationTests:14-15`.
2. `ProcessingQueueTests.swift:1264` · третий экземпемпляр sleep→негатив-ассерт (200мс) — к открытым `:172,198` · bounded waitUntil с дедлайном.
3. `RecordingStartTests.swift:227,249,268` (+ `RecordingSearchPerformanceTests.swift:119`) · бесконечные спины `while permission == nil { await Task.yield() }` без таймаута · регрессия вешает тест навсегда вместо падения · bounded-цикл с дедлайном.
4. `LocalizationTests.swift:12-33` · каталоги Interface.en.json (426 ключей) и Messages.en.json (537) проверяются по 4 выборочным ключам · потерянный перевод/рассинхрон плейсхолдеров не ловится · тест полноты ключей и плейсхолдеров.
5. `RecordingGroupIntegrationTests.swift:399-409,472-481` · DnD-типы схем (`app.localscribe.diagram[.group]`) не покрыты — проверяется только пара записей, при том что Info.plist экспортирует все 4 UTI · добавить диаграммную пару + drop-тест схемного sidebar.
6. `ContentLayoutTests.swift:284` · тест запрашивает реальный HAL для фиктивного deviceID=3 — на машине с занятым id поведение меняется от окружения · внедряемая заглушка (как HALInputRoute в `:279`).
7. `WorkspaceKeyboardTests.swift:314-316,398-400,448-450` · три копии ручного poll-цикла (бюджет 1 с) · общий waitUntil (5 с).
8. `ResultEditingTests.swift:346` · `sleep(100мс)` «пусть биндинг дойдёт до кнопки» перед проверкой enabled · bounded-поллинг с дедлайном.
9. `DiagramWorkspaceTests.swift:553-595` · UI sidebar'а схем покрыт только на уровне модели; rename через нативное поле, контекстные меню, порядок групп не тестируются · зеркалировать 2-3 ключевых теста записей.
10. Переходящие (подтверждены актуальными): копипаста worker-фикстуры `DiagramWorkspaceTests:16-66`; a11y-хелперы теперь ~8 копий (+AppErrorHandlerTests:145, RecordingActionsTests:51, ResultEditingTests:247, внутрифайловый дубль DiagramModeSwitchLayoutTests:770-784); `waitUntil` — 6 копий с разными сигнатурами/таймаутами; нет тестов ModelDownloadClient, `DiagramImageRegions.crops` (лимит 5 областей, порог 4 Мп, EXIF, sequence-fallback), live-цикла `LiveTranscriber.perform`, XPC-сервера, кодов выхода 70/73 и `--versions`.

**P3**

11. `ProcessingQueueTests.swift:705-723 и ещё ~9 тестов` · завершение без `model.shutdown()` — отложенные Task-и могут писать в удалённый root · teardown централизованно.
12. `BackgroundRecognitionTests.swift:20,32`, ContentLayoutTests, ModelCompatibilityTests, ResultEditingTests UI · 13 созданий AppModel — 0 shutdown · единый паттерн teardown.
13. `settle()` = sleep 100/120/180 мс в четырёх файлах · centralized retry-поиск с дедлайном.
14. `ArchiveResponsivenessTests.swift:71-73` · maxGap MainActor только печатается — тест не защищает контракт отзывчивости · щедрый порог (напр. <500 мс) или переименовать в измерение.
15. `ResultEditingTests.swift:255-261` · поиск alert по всему NSApp.windows с фильтром по label · сузить до sheet-attached.
16. `DiagramWorkspaceTests.swift:530` · мёртвое `_ = repo` · убрать из binding.

### 4.7 Скрипты, сборка, ресурсы

Проверено и в порядке: версии 2.11.0/21 синхронны (Info.plist = AppInfo = README); Package.resolved соответствует exact-пинам; models.lock.json консистентен (26 профилей, все ссылки resolver'ятся, у всех файлов size+sha256); entitlements соответствуют архитектуре (сеть только у XPC); download_models.py — образцовый (Range-resume, SHA, .partial, атомарная публикация).

**P2** (кроме P1-6/P1-7 из раздела 3)

1. `build_app.sh:21` · нет trap/cleanup: после `rm -rf "$APP"` падение любого шага оставляет полу-собранный `dist/LocalScribe.app`, который можно открыть · trap с удалением при ненулевом выходе или сборка во временный каталог с финальным перемещением.
2. `lock_models.py:93` (+ `lock_qwen_models.py:98`, `lock_vibevoice_models.py:48`) (переходящая) · models.lock.json перезаписывается `write_text` без атомарности — прерванная запись портит отслеживаемый файл · общий atomic write helper.
3. `lock_models.py:37-50` vs `lock_qwen_models.py:24-26` · два разных `get()`: у первого ретраи и кэш immutable-URL, у второго нет; vibevoice импортирует из qwen · дивергентная обработка сетевых ошибок · общий модуль `scripts/lib/hf.py`.
4. `probe_summary_speed.py:56` · `os.killpg(child.pid, SIGKILL)` для child, запущенного без `start_new_session=True` · killpg даст ProcessLookupError, а при совпадении с чужой группой может убить посторонние процессы · `start_new_session=True` (как в probe_asr_matrix.py:646).
5. `probe_asr_matrix.py:584` · жёсткий путь `TestResults/asr-word-repair-payment-20261020-final/...` (TestResults в .gitignore) · на другом клоне — неочевидный FileNotFoundError · параметр CLI с понятной ошибкой.
6. Нет CI (в репозитории нет .github/workflows) (переходящая) · 631 XCTest и 63 python-теста выполняются только вручную · минимум: GitHub Actions на arm64-macOS — python-тесты (без сети), `plutil -lint`, проверка синхронности версий Info.plist ↔ AppInfo ↔ README; сборка/XCTest — вторым этапом при доступности раннера.
7. `media_pipeline_checks.py:5`, `media_failure_checks.py:6` (переходящая) · жёсткий путь воркера · аргумент `--worker` c `swift build --show-bin-path`.
8. `probe_asr_settings.py:60-77`, `probe_asr_boundaries.py:107-124` · две дословные копии `launch()` из probe_asr_matrix · тройное дублирование самой опасной логики (killpg) · вынести в probe_asr_matrix.

**P3**

9. `build_ffmpeg.sh:9` · curl пишет напрямую в Vendor — оборванная загрузка оставляет усечённый кэш, следующая SHA-проверка требует ручного rm · temp+mv.
10. `licenses.py:5` · жёсткая зависимость от `.build/checkouts` без проверки · понятная ошибка.
11. `probe_live_capture.py:1` · единственный скрипт без shebang · добавить.
12. `smoke.py:39,41` (переходящая) · пути относительно CWD · ROOT от `__file__`; заодно `assert` → явные ошибки (там же и fault_checks.py).
13. `parent_exit_check.py` vs `resource_process_checks.py` · дублирование цели (SIGKILL родителя) · оставить второй, первый пометить deprecated.
14. `signed_probe.sh:10` · существующий ProbeModels не обновляется при смене профилей · сравнивать/перезаписывать.
15. `Resources/Info.plist:19-41` · нет CFBundleDocumentTypes для поддерживаемых аудиоформатов — двойной клик в Finder не открывает приложение (если это не осознанный дизайн — решение за владельцем, меняет поведение) · задокументировать решение.
16. `SystemAudioCapture.swift:183` · приватный Core Audio process tap: обновления macOS 26.x могут сломать захват · явная проверка в MacAcceptance на каждом минорном апгрейде ОС (graceful-fallback уже есть).
17. `README.md:127,132-133` (переходящая) · команда тестов без `--force-resolved-versions`; примеры с жёстким путём `.build/out/...` рядом с предупреждением о нём · поправить.
18. `models.lock.json` (переходящая) · diagram-профили без генератора · `lock_diagram_models.py` по образцу qwen.
19. `build_app.sh:7` · молчаливая сетевая зависимость: при отсутствии Assets/tools автоматически вызывается build_ffmpeg.sh · предупреждение перед запуском.
20. `Resources/ModelService-Info.plist:6` (переходящая) · CFBundleVersion XPC = 1 при 21 у приложения · синхронизировать (проверкой в тесте скриптов).

### 4.8 Документация

1. **P2** `ASRContinuation.md:229` (переходящая) · путь `Tests/LocalScribeTests/ASRWindowTests.swift` не существует (фактический — LocalScribeDiarizationTests); там же раздел «Карта реализации» описывает политику в старом месте · поправить или пометить историческим.
2. **P2** «Итог сессии 6» дублируется дословно в `ASRWindowing.md`, `ASRMatrix.md`, `ASRContinuation.md` (переходящая) · держать один раз в ASRExperimentStatus, в остальных — ссылки.
3. **P2** `ProjectReview-2026-10-18.md` · 19 ссылок `/Users/eugene/…` — машинозависимые, не работают у другого пользователя (переходящая) · относительные пути.
4. **P2** нет `docs/README.md` — указателя по 37 документам (нормативные vs замороженные отчёты сессий) (переходящая) · добавить индекс.
5. **P3** `docs/MicrophoneFix.json` — файл-сирота (переходящая) · удалить или связать.
6. **P3** размещение ревью непоследовательно: 10-18 и этот отчёт в `docs/`, 10-24 и 11-09 — в корне (переходящая) · выбрать одно место (рекомендую `docs/`) и перенести.
7. **Действие:** `docs/diagrams/` (7 схем + README, проверены на соответствие типам) — не закоммичен; также незакоммичен WIP-диф. См. раздел 5.

---

## 5. Незакоммиченный WIP — что доделать до коммита

Диф (`MicrophoneRecorder.swift` + 2 теста + `CapturePCM16.md`) — качественный рефакторинг ожидания первого пакета: корректное извлечение `waitForFirstMicrophonePacket` (локальная константа `expectedInput` в `checkConfiguration` правильно сохраняет старое значение для `previous:`), рестарт остановившегося при старте движка с требованием нового пакета, новое поведение смешанного режима («запись началась без микрофона» вместо молчаливого ожидания) покрыто тестами и документацией.

Перед коммитом:

1. **Исправить гонку P1-3** (in-flight callback между clear и restart) — единственный реальный дефект диффа.
2. Решить, как фиксировать поведение «система продолжает запись без микрофона» в тестах очереди (переход `CaptureMicrophoneStatus.waiting` при живом задании) — сейчас покрыто только на уровне ingress.
3. Закоммитить вместе с WIP неотслеживаемый `docs/diagrams/` (или отдельным docs-коммитом) — каталог полезный, но пока невидимый для команды.

## 6. Горизонтальные темы

1. **Асимметрия веток «записи/схемы» — главный систематический источник находок (третий раз подряд).** Координаторы (~70 % копипаста), сайдбары (~250 строк), pinned-source (две копии security-критичной механики), runCommand/runDiagram, два markdown-эскейпера, два резолвера models.lock, два launch()-дублирования в скриптах. За две недели расхождения добавились (onDiscard в catch, дубликат-поиск только в памяти). Рекомендация прежняя, но уже с конкретикой: generic `GroupStore`/`ArchiveState<ID, Manifest>`, общий протокол сайдбара, общий pinned-copy/launcher/escaper — устраняет класс расхождений, а не отдельные симптомы.
2. **`AppModel` — god-object, 1847 строк (+227 за две недели).** Диаграммная ветка, управление моделями, self-check'и, экспорт, live-захват и очередь в одном классе. Минимальная расшивка без изменения поведения: `DiagramQueueController`, `ModelManagementController`, вынос self-check; появится и естественная точка тестирования (сейчас тесты мутируют внутренности напрямую).
3. **Ресурсы на 3-часовых записях.** Диаризация 691 МБ + копия (единственная незакрытая ресурсная P2 из 09.11), двойной PCM-декод в ASR-окнах, обнуляющая заливка masks в embedder, тысячи actor-хопов токенизации. Ни одно не блокер, но вместе они определяют поведение на длинных встречах; перспективный шаг — замер `ru_maxrss` воркера на синтетическом 3-часовом прогоне в будущем verify.sh.
4. **Отсутствие CI/единой точки входа** — единственный автоматический барьер по-прежнему 63 python-теста. `scripts/verify.sh` (build + python-тесты + plutil + сверка версий) закрыл бы 80 % потребности до появления hosted-раннера macOS 26/Xcode 27.

## 7. Приоритизированный план действий

### Быстрые победы (часы, без риска)

1. WIP-гонка P1-3 → коммит WIP + `docs/diagrams/` (раздел 5).
2. `Dictionary(uniqueKeysWithValues:)` → `uniquingKeysWith` в AppModel (P1-4).
3. `package_source.sh` `--exclude=Vendor` + фикстуры теста (P1-6); SHA-пины в external_codec_checks (P1-7).
4. `onDiscard()` в catch `enqueueImport`; SHA-перепроверка схемы после VLM; `dup`-проверки в Worker; shutdown-таймаут.
5. Tie-break'ы и мелочи Core: двойной close в Media, guards DiagramExport, лимит gap в TimedCaptureWriter; убрать 4 предупреждения компилятора (§4.2 п. 21).
6. Тесты: teardown ImportQueueTests, третий sleep-паттерн `:1264`, bounded-спины RecordingStartTests, тест полноты LocalizationTests.

### Среднесрочно (дни)

7. Тесты menu bar (P1-5); зеркальные DnD/UI-тесты схемной ветки; общий TestSupport (a11y, waitUntil, worker-фикстура).
8. Системный звук до допуска (P1-1) и апгрейд маршрута без остановки рабочего микрофона (P1-2) — оба требуют продумывания шкалы origin и验收 на реальном железе (TCC/HAL); тесты через фикстуры ingress.
9. Неатомарная публикация модели (staging/RENAME_SWAP); непрерывность live-предпросмотра; peer-валидация XPC; мягкая деградация amendment.
10. Стартовая SHA-перепроверка → size+mtime; батчинг reload(); отмена preview-задач; дедупликация предупреждений.
11. Инфраструктура: trap в build_app.sh, атомарная запись lock-генераторов, `scripts/lib/hf.py`, `--worker` в media-checks, killpg-фикс probe_summary_speed, verify.sh + минимальный CI.
12. Документация: индекс docs/README, перенос ревью в одно место, фикс ASRContinuation, дедупликация «Итога сессии 6».

### Долгосрочно (недели, планировать отдельно)

13. Стриминг PCM окнами в диаризацию (требует адаптера SpeakerKit-снимка; bounded-канал уже есть).
14. Generic-слой веток записей/схем (координаторы + сайдбары + pinned-source) — тема №1 сопровождаемости.
15. Расшивка AppModel (DiagramQueueController, ModelManagementController, self-check).
16. Маркеры локальных правок QwenASR/VibeVoiceASR + автосверка патчей SpeakerKit; EOS/n_window из конфигов.
17. Уборка мёртвого кода ThirdParty (createBlockAttentionMask, encodeSingleWindow, MicrophoneCaptureWriter, hamming/powerToDB и др.) отдельной серией мелких коммитов с прогоном тестов.

## 8. Сильные стороны (сохранять)

- Целостность данных последовательно важнее удобства: двойная SHA-верификация импорта, pinned-FD с `O_NOFOLLOW/O_EXCL/CLOEXEC`, `renameatx_np(RENAME_EXCL)`, монотонные ревизии снимков, привязка транскрипта к fingerprint run'а.
- Систематическая защита от поздних async-ответов (UUID/signature/loadID/поколения) — за всё ревью найдено ровно две узких гонки (P1-3, lastError).
- Дисциплина отмены: checkCancellation до/после SDK-вызовов во всех движках, terminateGroup + drain обоих readers, watchdog на заблокированном EOF.
- Диагностика ошибок (новое с 09.11): копируемые «Технические сведения» содержат только нейтральные факты; расшифровка сигналов (код 5 = SIGTRAP и т. д.) реально помогает поддержке без утечки текста разговора.
- Retry VibeVoice (asr12): ограниченная рекурсия (60 с → 3,75 с), сокращение контекста на коротких окнах, отказ без частичного результата — полностью покрыт тестами, версии policy/pipeline корректно подняты.
- Тесты проверяют целостность, а не «зелёность»: реальные worker-процессы и pipe-протокол, краш-тест SIGTRAP, контроль утечек FD, побайтовые сравнения.
- Документация честная: разделение «проверено/частично/ожидает», история версий конвейера, AGENTS.md точно совпадает с кодом.

## 9. Ограничения ревью

- Ревью только чтением; запускались лишь безопасные проверки: сборка релиза (см. ниже) и статические сверки. XCTest не запускались; статус 631 тест/0 ошибок взят из AGENTS.md на 11.11.2026.
- Проверки TCC/настоящего микрофона, установленной .app, подписи/Gatekeeper, WER/DER на реальных встречах, Instruments — вне объёма; блокеры сессии 6 (перевод русских реплик, ошибки/дубли итогов, лимит summary15) остаются открытыми по ASRExperimentStatus.
- Патчи SpeakerKit сверены с upstream.json по SHA и логике, но повторное применение патчей к свежей ревизии upstream не выполнялось.
- Строки кода указаны на момент ревью (рабочее дерево с WIP); после правок строки сдвинутся.
