# Ревью проекта LocalScribe — 09.11.2026

Полное ревью репозитория `meetings_AI` (LocalScribe): все 297 отслеживаемых файлов, ~38 тыс. строк Swift в Sources/ThirdParty, ~17 тыс. строк тестов, ~4 тыс. строк скриптов, ~6,6 тыс. строк документации. Каждая находка проверена чтением кода и сопровождена ссылкой на файл и строку. Изменения в код не вносились; для проверки здоровья проекта запускались только безопасные операции: `swift build -c release -j 4 --force-resolved-versions` (успех, предупреждений нет) и `python3 -m unittest discover -s scripts/tests` (63 теста, 0 ошибок).

## Резюме

Проект в целом образцового качества для локального ML-приложения: дисциплина целостности данных (двойные SHA-проверки, атомарные записи, монотонные ревизии), продуманная изоляция процессов и sandbox, честная документация, реальные процессы вместо моков в тестах. Проблем уровня P0 (потеря данных, коррупция архива, дыры в изоляции) не найдено.

Главные зоны роста — не «исправить сломанное», а устранить накопившуюся асимметрию и дублирование:

1. **Шесть проблем P1**: неполная SHA-валидация моделей в worker, отложенная загрузка NSItemProvider при импорте записей, наращивание .app поверх старого содержимого при упаковке, flaky-паттерн в самых критичных тестах очереди, две существенные неточности в документации.
2. **Асимметрия веток «записи/схемы»**: диаграммная ветка реализована позже и лучше (tie-break сортировки, ограничение чтения по size, фиксация снимка до модальной панели). Улучшения не портированы обратно в аудио-ветку, а параллельный код расходится — это источник большинства конкретных находок.
3. **Сопровождаемость**: `AppModel` (1620 строк, ~10 ответственностей), дублирование sidebar'ов (~64 %), копипаста тестовых хелперов.
4. **Ресурсы**: диаризация держит весь 3-часовой PCM в памяти одним массивом (~691 МБ).
5. **Инфраструктура**: нет единой точки входа для проверок (verify.sh/CI), три генератора моделей различаются по качеству, diagram-профилям каталога не хватает генератора.

### Топ-10 по приоритету

| # | Проблема | Область | Приоритет |
|---|----------|---------|-----------|
| 1 | Whisper/диаризация/итоги грузятся без SHA-валидации закреплённых файлов | Worker | P1 |
| 2 | Импорт записей: `NSItemProvider.load` стартует отложенно, вне drop-обработчика | GUI | P1 |
| 3 | `build_app.sh` не очищает старый `.app` — stale-файлы уезжают в дистрибутив | Скрипты | P1 |
| 4 | Диаризация держит весь PCM 3-часовой записи в памяти (~691 МБ) | Worker | P2 |
| 5 | Гонка: `enqueueDiagram` не перепроверяет `deletingJobIDs` после await | GUI | P2 |
| 6 | ⌘⌫ перестаёт работать после клика по read-only тексту результата | GUI | P2 |
| 7 | Негативные ассерты после фиксированного `sleep(300мс)` — flaky-риск | Тесты | P1 |
| 8 | Дублирование веток записей/схем и sidebar'ов (~64 %) | Core+GUI | P2 |
| 9 | `AppModel` — god-object, 1620 строк, ~10 ответственностей | GUI | P2 |
| 10 | Рассинхрон документации (asr9/asr10, список моделей) и отсутствие verify.sh | Docs+Скрипты | P1–P2 |

---

## Сильные стороны (сохранять)

- **Целостность данных последовательно важнее удобства**: двойная верификация SHA при импорте (пиннинг FD → хэш → независимая копия → повторный хэш), привязка транскрипта к fingerprint run'а, побайтовое сравнение PCM в `CaptureIntegrity.verify`, RENAME_EXCL-публикация моделей через staging, `O_NOFOLLOW`/`O_EXCL`/`FD_CLOEXEC`, удержание лидера группы процессов до EOF с защитой от рециклинга PID. Уровень редко встречается в прикладном Swift.
- **Систематическая защита от поздних async-ответов**: UUID `loadID` + `signature` в `loadResult`, тройная проверка в `DiagramWorkspaceModel`, поколения в `RecordingSearch`, admission/generation в очереди. Дыра нашлась ровно одна (см. P2 про `enqueueDiagram`).
- **Дисциплина отмены**: `Task.checkCancellation()` до и после каждого SDK-вызова во всех трёх ASR-адаптерах; `terminateGroup` + drain обоих pipe readers; stderr дренируется без сохранения (приватность текста разговора).
- **Опасные эксперименты изолированы**: gap recovery / context review / word repair / late pause доступны только через `WhisperRecognitionPolicy` с production-дефолтом off; `candidate/proposed` в продакшене не строятся.
- **Патчи SpeakerKit задокументированы**: `upstream.json` с SHA каждого upstream-файла, порядок применения 7 патчей, каждому патчу — свой адверсариальный набор тестов; `DiarizationChannel` — корректный bounded lossless-канал.
- **Тесты проверяют целостность, а не «зелёность»**: сверка байтов до/после операций, реальные worker-процессы и pipe-протокол, контроль утечек FD, ассерты на отсутствие текста расшифровок в метриках/stderr.
- **Документация честная**: последовательное разделение «проверено/частично/ожидает», отказ выдавать синтетические пробы за WER/DER-приёмку; версии в AGENTS.md точно совпадают с кодом.

---

## 1. Sources/LocalScribeCore (25 файлов, ~4,3 тыс. строк)

Все файлы прочитаны полностью. P0/P1 нет.

### Важное (P2)

- **[P2] `Sources/LocalScribeCore/ImportSource.swift:47-52` — копирование не ограничено закреплённым размером файла.** `ImportSource.copy` читает до EOF без ограничения по `size` из `fstat`, тогда как параллельный `PinnedImageSource.copy` (`DiagramRepository.swift:327-335`) читает ровно `size` байт и отклоняет растущий файл. Если в аудио-файл дописывают между `hash()` и `copy()`, импорт выполнит всю работу и лишь затем откажется («Не удалось проверить сохранённый оригинал»). Коррупции нет, но это ложный сбой плюс неограниченное чтение. Как исправить: перенести паттерн `while count < size` из `PinnedImageSource` в `ImportSource` (или извлечь общий хелпер).

- **[P2] `Sources/LocalScribeCore/Models.swift:280-281` — построение URL загрузки дублирует `ModelProfile.downloadURL` с force-unwrap.** `ModelInstaller.install` собирает адрес заново: `URL(string: "https://huggingface.co/…")!` — при некорректных `repository`/`revision` приложение упадёт по `!`, тогда как `ModelProfile.downloadURL` (строки 41-48) валидирует и бросает понятную ошибку. Реализации к тому же расходятся (percent-encoding есть только в инсталлере). Как исправить: единый метод с encoding, убрать `!`.

- **[P2] `Sources/LocalScribeCore/DiagramCoordinator.swift:107-116` — каждое удаление схем делает полный рескан архива.** `delete(_ ids:)` в успешном пути всегда вызывает `replace(readListing())` — перечитывает `manifest.json` каждого элемента, включая одиночные удаления из карточки. `RecordingCoordinator.delete` (строки 181-182) в том же случае фильтрует in-memory. Для сотен схем это O(n) дисковых чтений и JSON-декодов на каждый delete. Как исправить: фильтровать in-memory, `readListing()` — только в catch-ветви (как в аудио-ветке).

- **[P2] `Sources/LocalScribeCore/RecordingGroups.swift:90-122` + координаторы — дублирование нейтральных хелперов между ветками.** `loadGroups`/`saveGroups` и статические `loadCatalog`/`writeCatalog` — идентичные ~10 строк; `RecordingCoordinator` (строки 77-91, 185-224, 252-301) и `DiagramCoordinator` (252-315) содержат почти идентичные `replace`/`publish`/`positions`/`readListing`/`initializeGroups`/`pruneDeletedMembership`/`reserveDestination` (~90 строк на сторону). Хелперы уже не зависят от типа манифеста. Как исправить: generic `GroupStore`/`ArchiveState<ID, Manifest>` — сократит дублирование без смешивания веток и уберёт уже возникшие расхождения (см. P3 про tie-break и guard).

### Мелкое (P3)

- **[P3] `Repository.swift:47`, `RecordingCoordinator.swift:88` — сортировка без tie-break при равном `createdAt`.** Swift `sorted` не стабилен: у записей с одинаковой датой создания (батчный импорт) порядок в снапшоте может дрожать между публикациями. Диаграммная ветка уже решает это (`DiagramRepository.swift:81`, `DiagramCoordinator.swift:279-281` — tie-break по `id`). Добавить `$0.id < $1.id` в оба места аудио-ветки.
- **[P3] `Repository.swift:96` — guard live-захвата пропускает каталог без ASR-модели.** `…?.supportsClosedFragments != false` при отсутствии профиля даёт `true`; `Pipeline.swift:62` использует строгое `== true`. Привести к `== true`, чтобы Core-инвариант не полагался на вызывающих.
- **[P3] `RecordingCoordinator.swift:114` — `flushIndex` полностью глотает ошибку записи `index.json` (`catch { }`).** При устойчивой ошибке индекс молча остаётся устаревшим навсегда. Индекс вспомогательный, но хотя бы диагностический хук стоило бы оставить (как в `observeIO`).
- **[P3] `Contracts.swift:195-226` — квадратичные проверки Summary.** `validate`/`groundingOptionalFields` на каждый finding делают до трёх проходов по всем сегментам с вложенным `evidenceSegmentIds.contains` — O(F×E×S) сравнений строк; для трёхчасовой встречи это десятки миллионов сравнений. Построить один раз `[String: Segment]` и проверять по словарю (заодно ускорит `evidenceContext` в `SummaryAnalysis.swift:107-113`).
- **[P3] `Models.swift:312` — обрыв потока до `expectedSize` маскируется под SHA-ошибку.** EOF до ожидаемого размера молча выходит из цикла, после чего пользователь получает «Не совпала SHA-256…», хотя причина — прерванный источник. Проверять `count == expectedSize` и бросать отдельное сообщение.
- **[P3] `DiagramCoordinator.swift:305` — `pruneDeletedMembership` не учитывает идущую выемку группы.** Аудио-ветка проверяет `deletingGroups.isEmpty` (`RecordingCoordinator.swift:186`), диаграммная — только `groupsError`. Сейчас безопасно (membership заморожен), но это ещё одно незеркалированное расхождение, которое легко ломается при будущих правках. Добавить `groupDeletion == nil` в guard.
- **[P3] `Analysis.swift:36` — нестабильная сортировка сегментов при назначении спикеров** (`sorted { $0.startMs < $1.startMs }` без tie-break): перекрывающиеся сегменты с равным `startMs` могут переставляться, влияя на нумерацию `seg-XXXXXX`. Добавить tie-break по исходному индексу.
- **[P3] `ModelLibrary.swift:21` — безусловная запись `selection.json` при каждой загрузке**, даже когда ничего не изменилось — лишняя запись и обновление mtime на каждом старте. Сравнивать состояние перед записью.
- **[P3] `Export.swift:25-27` — `ExportService.render` используется только тестами** (production идёт через `renderResult`). Перенести вызов в тесты или пометить как тестовое удобство.
- **[P3] `RecordingCoordinator.swift:138-142` + `Repository.swift:49-56` — rename читает манифест трижды** (load→save в repository + ещё load в координаторе). Вернуть манифест из `rename`, убрав лишний дисковый round-trip.
- **[P3] `Media.swift:217` — force-unwrap `AVAudioPCMBuffer(…)!`** при остальном аккуратном `ScribeError`-стиле (`samples`, строка 188). Отказ аллокации даст краш; заменить на `guard let`.

---

## 2. Sources/LocalScribe — GUI (30 файлов, ~5,8 тыс. строк)

Все файлы прочитаны полностью (`AppModel.swift` — частями).

### Важное

- **[P1] `Sources/LocalScribe/AppModel.swift:487` — загрузка NSItemProvider стартует отложенно, а не в drop-обработчике.** `importProviders` кладёт в очередь замыкание `try await DroppedFileURL.load(provider)`, т.е. `provider.loadObject` вызывается только когда `ImportQueue` дойдёт до элемента — после всех предыдущих импортов (probe + SHA + копия могут идти минутами). Комментарий в `ImportQueue.swift:92` прямо требует начинать загрузку в синхронном drop-callback; часть провайдеров после окончания drag-сессии может не ответить — импорт молча зависнет. У записей, в отличие от схем, нет и `onDiscard`, т.е. `ImportQueue.cancel()` не отменяет ожидающие provider-загрузки. Как исправить: перенести паттерн диаграммной ветки (`DiagramWorkspaceModel.swift:179-180`: `start(provider)` синхронно, `value()` в очереди, `onDiscard: { request.cancel() }`).

- **[P2] `Sources/LocalScribe/AppModel.swift:1317, 1344` — `enqueueDiagram` не перепроверяет `deletingJobIDs` после suspension.** Начальный guard (1302) проверяет удаление, но после `await diagramArchive.load(id)` повторные guard'ы проверяют только `generation`/`enqueuing`/`activeJob`. Если удаление схем началось во время `load`, enqueue успеет сделать `beginRun` и поставить в очередь задание для удаляемого манифеста — лишний run и ошибка чтения удалённого элемента. Аудио-ветка перепроверяет корректно (`AppModel.swift:750-752`). Как исправить: добавить `!deletingJobIDs.contains(job)` в оба guard'а.

- **[P2] `Sources/LocalScribe/AppModel.swift:809, 815` — безусловная перезапись `lastError` в catch `processQueue`.** Когда `stopRecording` (591-597, 612-615) уже записал информативную причину («Микрофон ещё не передал звук…», «Фрагменты сохранены. Нажмите „Продолжить“…»), catch очереди после снятия activeJob записывает generic «Обработка прервана…» независимо от терминального состояния; порядок двух конкурирующих `archive.update` недетерминирован. Как исправить: писать `lastError` только вместе с изменением state/captureProcessing либо не трогать при уже терминальном состоянии.

- **[P2] `Sources/LocalScribe/WorkspaceKeyboardShortcut.swift:35-37` — ⌘⌫ блокируется не-редактируемым текстом результата.** `guard text == nil else { return event }` отбрасывает ⌘⌫, если firstResponder — любой `NSTextView`, включая read-only транскрипт. После одного клика по тексту результата удаление выделения перестаёт работать до смены фокуса. Ветка Esc (строка 33) корректно различает: `text.isEditable || text.isFieldEditor || text.hasMarkedText()`. Применить тот же предикат для ⌘⌫.

- **[P2] `Sources/LocalScribe/AppModel.swift` (весь файл, 1620 строк) — god-object с ~10 ответственностями.** В одном `@MainActor`-классе: движок очереди (admission/generation/pauses, 735-827), live-захват и финализация (522-655, 712-734), импорт (481-521), управление моделями (325-475), вся диаграммная ветка (1236-1434), группы и sidebar-проекция (1083-1235), экспорт/копирование (1438-1487), self-check (1509-1619), наблюдатели памяти/сна. Это главная причина сложности рассуждений о гонках. Минимальная расшивка без изменения поведения: `DiagramQueueController` (≈1236-1434), `ModelManagementController` (325-475), вынос self-check'ов (≈110 строк) в отдельный тип; очередь и live-захват оставить в AppModel.

- **[P2] `RecordingGroupsSidebar.swift` vs `DiagramGroupsSidebar.swift` — дублирование ~64 %.** Нормализованный diff: 1041 из 1611 токенов структурно совпадают. Зеркальны каркас `body` (26-130 против 24-126), `DropDelegate` группы, `GroupOrderDrop`, insertion line, заголовок группы, deletion-views — ~250-280 дублируемых строк на файл. Уже есть shared-примитивы, но не хватает generic-слоя «архив sidebar»: протокол (groups/search/selection/порядок/visible/move/rename/delete) + параметризованные row-модификаторы + generic `GroupDrop`/`GroupOrderDrop`. Сократит ~200 строк и уберёт уже разошедшиеся поведения (см. следующий пункт).

### Мелкое (P3)

- **[P3] `DiagramGroupsSidebar.swift:69` vs `RecordingGroupsSidebar.swift:74` — пустая подсказка группы при активном поиске**: схемы показывают «Загрузите изображение…» для группы без совпадений (не гейтят `!search.active`); также микро-расхождения drag-handle при поиске, `.disabled` заголовка (весь vs только кнопка удаления), учёта фокуса для видимости контролов.
- **[P3] `AppModel.swift:18, 47-53, 248-249` — двойной вызов `recordingSearch.update` на каждый снапшот** (срабатывают оба `didSet` — и `recordings`, и `recordingGroups`), каждый раз с O(n)-пересборкой массивов до guard'а «не изменилось». Единая точка обновления в `applySnapshot`.
- **[P3] `AppModel.swift:1060, 1119, 1222, 1351, 1389` — `jobAdmission` растёт неограниченно**: записи никогда не удаляются, словарь накапливает все когда-либо отменённые UUID за сессию. Чистить вместе с `deletingJobIDs` по surviving-списку.
- **[P3] `ResultEditorView.swift:65` — глубокое сравнение транскрипции на каждое нажатие клавиши** (`draft.transcript == initial.transcript` — value-type дерево из тысяч реплик). Заменить на счётчик правок/ревизию в черновике.
- **[P3] `AppModel.swift:1460-1465` — экспорт записей не фиксирует снимок до модальной панели.** render-замыкание читает актуальные `transcript/summary/revision` после закрытия `NSSavePanel` — пока панель открыта, `checkpoint → loadResult` может обновить результат, и в файл уйдёт не то, что видел пользователь. Схемы делают правильно (`DiagramWorkspaceModel.swift:233-241`). Зафиксировать manifest/transcript/summary/revision до `runModal`.
- **[P3] `AppModel.swift:467-475` — `removeModel` удаляет каталог модели синхронно на MainActor** (`FileManager.removeItem` по дереву + сохранение selection.json из вызова UI). `Task.detached` + повторный вход для `updateModelsStatus` (паттерн `verifyModels`).
- **[P3] `DiagramWorkspaceModel.swift:55-60` — Combine sink без изоляции MainActor**: корректность держится на том, что `@Published` эмитит на main, и комментарий это осознаёт. При переводе target'ов на Swift 6 — ошибка/тихое изменение семантики. Аннотировать замыкание.
- **[P3] `AppModel.swift:842-906` — сбитый отступ `processRecordingJob`**: тело после guard'а сдвинуто на лишний уровень, закрыто одиноким brace. Ключевая функция конвейера — механический фикс читаемости.
- **[P3] `RecordingDetailColumn.swift:131-133` — `onDrop` безусловно возвращает `true`**, даже когда `enqueueImport` молча отбрасывает дроп по guard'у — Finder считает дроп принятым. Вернуть признак принятия (как в диаграммном приёмнике).
- **[P3] `AppModel.swift:47` — асимметрия инкапсуляции**: `@Published var recordings` (публичный сеттер) против `@Published private(set) var diagrams`. Привести к `private(set)`.
- **[P3] `AppModel.swift:1234` — `deleteGroup` сбрасывает selection в nil**, тогда как `applySnapshot` (252-254) переносит выбор на выжившую запись. Использовать ту же retain-логику.

---

## 3. Sources/LocalScribeWorker + ModelService + CWorkerIsolation (22 файла, ~3 тыс. строк)

Все файлы прочитаны полностью.

### Важное

- **[P1] `Sources/LocalScribeWorker/ASREngine.swift:17-19` (также `WhisperASREngine.swift:47-49`, `Pipeline.swift:174-178`, `SummaryEngine.swift:51`) — Whisper-ASR, диаризация и итоги грузят модели без проверки SHA-256 закреплённых файлов.** Полная валидация (`profile.validate(at:)` — размеры + SHA всего комплекта, `Models.swift:58-65`) выполняется в worker только для Qwen/VibeVoice (`PinnedASRFiles.validate`, ASREngine.swift:93) и схем (`DiagramEngine.swift:151`). `loadWhisper` просто передаёт папку в WhisperKit (токенизатор проверяется через `FileManager.fileExists`) — это прямо противоречит собственному комментарию-инварианту `PinnedASRFiles` («Every path read by a native SDK must itself be present in the frozen catalog»). Диаризация (`Pipeline.inferSpeakers`) и итоги (`LLMModelFactory.loadContainer`) тоже не перепроверяют файлы. Последствие: повреждённый/подменённый после установки комплект молча даст неверную расшифровку или итоги, которые опубликуются как валидные (fingerprint привязан к аудио, не к модели). Как исправить: вызывать `PinnedASRFiles.validate` для Whisper и `profile.validate(at:)` для ролей `.diarization`/`.summary` в `Pipeline.performStage` перед загрузкой — по образцу схем.

- **[P2] `Sources/LocalScribeWorker/Pipeline.swift:177` — диаризация держит весь 3-часовой PCM в памяти одним массивом.** `Media.samples(wave)` без `start/duration` декодирует весь WAV: 10 800 с × 16 000 Гц × 4 байта ≈ **691 МБ `[Float]`** плюс внутренние буферы SpeakerKit поверх. Для заявленного лимита «3 часа включительно» это главный пик RSS воркера. API `SpeakerKit.diarize(audioArray:)` требует массив целиком, но сегментация идёт окнами — можно стримить окнами в segmenter/embedder (в локальном снимке SpeakerKit bounded-канал уже есть) либо как минимум зафиксировать бюджет памяти в `ModelHardware`/документации. То же в `Worker.probeDiarization` (`Worker.swift:143`).

- **[P2] `Sources/LocalScribeWorker/QwenASREngine.swift:72-74` — двойной полный скан окна на проверку тишины.** `samples.contains(where: { $0 != 0 })` выполняется дважды (для метрик и для ветвления) — до ~0,5 МБ прохода на каждое окно, сотни окон на 3-часовой записи. Вычислить один раз.

- **[P2] `Sources/LocalScribeWorker/Pipeline.swift:32-36` — `capture-run.json` читается без проверки `schemaVersion`.** Для `run.json` проверка `info.schemaVersion == 1` есть (строка 24), для capture-копии сравниваются только id/fingerprint/modelIDs — декод старой/чужой схемы с совпадающими полями пройдёт. Добавить проверку (конвенция «Проверять schemaVersion перед использованием»).

- **[P2] `Sources/LocalScribeWorker/Worker.swift:83, 106` — сбой записи метрик проваливает успешный этап.** `try Disk.write(metrics, …)` стоит после `pipeline.perform()`/`engine.recognize()`: отказ ФС при записи `metrics-*.json` покажет пользователю «failed» при готовом артефакте. Метрики диагностические — `try?` с комментарием (как уже сделано в `ASRMetricsRecorder.save`).

- **[P2] `Sources/LocalScribeWorker/LiveTranscriber.swift:51-54` — термогейт тормозит и реплей готовых чекпойнтов.** Проверка `thermalState` с `Task.sleep(2s)` стоит до ветки чтения существующего чекпойнта (строка 58): при возобновлении 3-часового фонового задания на горячем Mac реплей до 360 чекпойнтов будет идти по 2 с на часть (~12 минут чистой задержки). Переставить проверку после ветки с готовым чекпойнтом.

### Мелкое (P3)

- **[P3] `LiveTranscriber.swift:19-20` — повторное чтение `models.lock.json` и повторный `catalog.pinned(to:)`** (Pipeline уже это сделал). Передать параметром.
- **[P3] `QwenASREngine.swift:62-68`, `WhisperASREngine.swift:72-76` — двойное декодирование PCM на каждое окно** (planning-чтение и рабочее чтение перекрываются, каждое independently открывает `AVAudioFile`). На 3 часах ~2× PCM-декода сверх инференса: читать один диапазон и нарезать срезы.
- **[P3] `VibeVoiceASREngine.swift:49-52` — нет пер-вызовных метрик**: Qwen пишет `backendCall(seconds:alignment:)`, VibeVoice — только `backend(...)`; `backendASRSeconds` для него всегда nil. Добавить `backendCall` вокруг `generate`.
- **[P3] `QwenASREngine.swift:59-99` + `VibeVoiceASREngine.swift:34-60` — дублирование скелета адаптеров** (цикл по coreRange, readStart/readEnd с контекстом, `Media.samples`, проверка длины, отмена, нейтральный `ScribeError`). Общий хелпер «окно → сэмплы + границы» сократил бы расхождение конвенций.
- **[P3] `Pipeline.swift:54` vs `DiagramEngine.swift:270-279` — два разных способа поиска `models.lock.json`** (аудио требует `toolsPath` и ровно один кандидат; схемы — три кандидата, `toolsPath` опционален). Свести к одному резолверу.
- **[P3] `Sources/LocalScribeModelService/Service.swift:30` — force-unwrap `Bundle.main.resourceURL!`** — упадёт молча вместо нейтральной ошибки. `guard let`.
- **[P3] `Worker.swift:134` — `try! JSONEncoder().encode(text)` в error-ветке probe** — теоретический крэш в диагностике; `try? … ?? Data()`.
- **[P3] `SummaryEngine.swift:54` — force-unwrap `String(data:…, encoding: .utf8)!`** — бессмысленная распаковка; `String(decoding:as:)` как в `:235`.
- **[P3] `ASRMetrics.swift:84` + `ASREngine.swift:16` — `ASRMetricsRecorder` (non-Sendable class) пересекает `@Sendable`-границы фабрики**: компилируется только в Swift 5-режиме executable-таргета; к миграции воркера на Swift 6 нужен `@unchecked Sendable` с документацией или actor.
- **[P3] `SummaryEngine.swift:56-58` (`SummarySourceIndex.swift:13-19`) — токенизация каждой реплики отдельным `await container.perform`**: тысячи actor-хопов на 3-часовой встрече. Батчировать (передавать массив строк в один вызов).
- **[P3] `Pipeline.swift:49` — статус `"cancelled"` в метриках недостижим**: отмена реализована как EOF stdin → `terminateGroup(72)` — процесс умирает через `_exit`, Swift-задачи никто не отменяет; ветка `CancellationError` срабатывает только в тестах и вводит в заблуждение при чтении диагностики. Документировать или отменять задачу перед terminateGroup.
- **[P3] `DiagramEngine.swift:191-219` — корректирующий проход запускается и для легитимных окончательных ответов**: «не похоже на схему» (`isDiagram:false`) и «Ответ превышает размер» — валидные вердикты, но попадают в общий catch и дают лишний полный VLM-проход на каждую не-схему. Разделить: коррекция — только для структурных дефектов JSON.

**CWorkerIsolation/WorkerIsolation.c** — замечаний нет: probe-коннект признаёт отказ только по EPERM/EACCES, унаследованный sandbox не реинициализируется, при недоказуемости ставится `(deny network*)` с перепроверкой, любая неудача → код 70 (fail-closed). IPv4/TCP-проба покрывается глобальным `deny network*`.

---

## 4. Тесты (73 файла, ~17 тыс. строк)

Все файлы прочитаны полностью; покрытие сопоставлено с Sources.

### Важное

- **[P1] `Tests/LocalScribeUITests/ProcessingQueueTests.swift:172, 198, 1228` — негативные ассерты после фиксированного sleep.** Паттерн «waitUntil → `Task.sleep(300ms)` → AssertFalse(…running / events.jsonl)» проверяет, что *ничего не произошло* за окно: на нагруженном раннере 300 мс может не хватить для позднего спавна worker — ложный провал самого критичного набора (инвалидация pause/cancel, FIFO). Заменить на детерминированный барьер: ждать условия-«тишины» по наблюдаемому состоянию с двойным квитированием.

- **[P2] Пробелы покрытия:**
  - `Sources/LocalScribe/ModelDownloadClient.swift` — **0 тестов**, хотя AGENTS.md прямо требует семантику «URLSessionDownloadTask + привязка callback к requestID» (отмена, поздний callback). Core-часть покрыта loopback-фикстурой, GUI-обёртка нет.
  - `DiagramImageRegions.crops(from:)` — нет прямых юнит-тестов (косвенно 2 сценария): не покрыты лимит 5 областей, порог 4 Мп, отказ при EXIF-повороте, fallback при диаграмме последовательности. Функция статическая и чистая — тесты дёшевы.
  - `LiveTranscriber.perform` — не покрыт сам live-цикл ожидания фрагментов («ждать новые part-*.caf → инкрементальные checkpoints → seal между сканом и чтением»), лимит 1081 фрагментов, отмена в ожидании. Ядро фоновой записи.
  - `SummaryEngine.summarize()` — покрыт только путь отказа; оркестрация extract→verify→amend→validate→запись `summary.json` с заглушкой LLM не собрана в один тест.
  - `Worker.swift` — не покрыты коды выхода 70/73 и ветка `--versions`.
  - `Service.swift` — сам XPC-сервер не тестируется (покрыта только клиентская обёртка).
  - `MicrophoneRecorder.swift` — 0 прямых тестов (осознанно: TCC/железо; частично покрыт косвенно).

- **[P2] `DiagramWorkspaceTests.swift:16-66` — копипаста worker-фикстуры из `ProcessingQueueTests.swift:37-66`** (~50 строк python-скрипта, включая формулу fingerprint продакшна): при изменении протокола фикстуры разойдутся молча. Вынести в общий ресурс/хелпер target'а.

- **[P2] 7-кратное дублирование accessibility-хелперов** (`descendants`/`findElement`/`host`/`settle`/`text`) в ContentLayoutTests (10-61 и 626-653), RecordingGroupIntegrationTests (21-40), WorkspaceKeyboardTests (56-71), RecordingSearchIntegrationTests (214-221), ResultEditingTests (196-199), RecordingActionsTests (51-72) — с расхождениями (settle 100/120/180 мс). Один файл `TestSupport`.

- **[P2] `ProcessingQueueTests.swift` (1255 строк) и `RecordingGroupIntegrationTests.swift` (860) превышают разумный размер** и смешивают темы (FIFO/паузы + automatic-summaries + групповые удаления; native-клики + DnD + редактор имени + подтверждения). Разбить на 3-4 suite по темам.

- **[P2] `waitUntil`-хелпер размножен в 4 экземплярах с разной семантикой** (ProcessingQueueTests 93-97, DiagramWorkspaceTests 96-100 — без сообщения при таймауте; ImportQueueTests 45-49; правильный вариант с Bool+timeout — WorkerSupervisorTests 23-27). Унифицировать.

### Мелкое (P3)

- **[P3] `ModelCompatibilityTests.swift:156, 195-213` — фиксированные sleep 100-200 мс** для пропагации SwiftUI. Заменить polling-ожиданием нужного элемента.
- **[P3] `ModelDownloadTests.swift:83-86` — сверка множества файлов по всему `/tmp`**: параллельный процесс с `localscribe-model-*` ломает ассерт. Ограничить собственным подкаталогом фикстуры.
- **[P3] `ModelHardwareTests.swift:11-18`, `ASRContractTests.swift:26-62` — жёсткая привязка к содержимому `models.lock.json`**: при перегенерации каталога сломаются. Похоже на осознанные контракт-тесты — пометить intent комментарием.
- **[P3] `DiagramVLMFixtureTests.swift:38` — `readToEnd()` без таймаута**: зависший worker повесит XCTest навсегда. Дедлайн-цикл как в DiagramRoutingTests 46-52.
- **[P3] `DiagramRoutingTests.swift:14-27` — перебор путей бинарника включая legacy `.build/out/Products/Release`**: при миграции сборки тест молча возьмёт устаревший бинарник. Логировать выбранный путь.
- **[P3] 6 тестов ProcessingQueueTests завершаются без `model.shutdown()`** (705-723, 773-800, 801-818, 876-895, 896-917, 918-944) — фоновые задачи живут до dealloc, возможны поздние записи в удалённый `root`.
- **[P3] `ModelCompatibilityTests.swift:29-31, 106-107`, `ImportQueueTests.swift:44` — UserDefaults-suite не удаляется после теста** — в `~/Library/Preferences` копятся plist с UUID-именами. Teardown по образцу ProcessingQueueTests:85.
- **[P3] `ContentLayoutTests.swift:356` — `XCTUnwrap(window.screen)` упадёт в headless-окружении** вместо осмысленного skip. Обернуть в XCTSkip.
- **[P3] `ResultEditingTests.swift` существует в двух target'ах с одинаковым именем** — фильтрация по имени запутывает. Переименовать UI-файл в `ResultEditingWorkspaceTests.swift`.
- **[P3] `RecordingGroupIntegrationTests.swift:796-825` — method-swizzling `NSView.beginDraggingSession`** как замена тестового seam — указывает, что в продакшн-DnD нет наблюдаемой точки (injectable-провайдер операций). Аналогично `accessibilityValue` через `perform(selector)` (565-571) — хрупко к смене macOS.
- **[P3] `ProcessingQueueTests.swift:885, 1054, 714` — прямые мутации внутренностей AppModel** (`supervisor.recordingActive = true`, `finalizingRecording = true`, `modelLibrary = …`) — сигнализируют об отсутствии тестовых фабрик; при рефакторинге полей сломаются компиляцией.
- **[P3] `settle()` = фиксированные 100/120/180 мс** в четырёх файлах — замедляет suite, мягкий flaky-риск; где можно, ждать конкретный элемент в цикле.

---

## 5. ThirdParty (46 файлов, ~9,1 тыс. строк)

Все файлы прочитаны полностью, патчи сверены с исходниками. P0/P1 нет.

### Важное (P2)

- **[P2] `ThirdParty/SpeakerKit/Sources/SpeakerKit/Pyannote/SpeakerEmbedderModel.swift:230, 263, 305, 402` — непроверенная геометрия masks/выхода embedder: краш вместо ошибки этапа.** `speakerDimensionForMasks()` при отсутствии описания `speaker_masks` возвращает 0 (только `Logging.error`), после чего индексация даёт out-of-bounds NSException; `embeddingsOutput[chunkSpeakerIdx]` (:305) — без проверки против `shape[1]`. При этом `model-geometry.patch` заявляет «некорректная модель завершает этап ошибкой», но не сверяет размерности с `windowsCount*speakersCount` — рассогласованные segmenter/embedder пройдут загрузку и уронят процесс worker в рантайме. Как исправить: проверять обе размерности в `SpeakerEmbedderContext.init` и бросать `SpeakerKitError.invalidModelOutput`.

- **[P2] `SpeakerEmbedderModel.swift:56, 64-72` — кадровые индексы из Float-усечений могут разойтись с `framesPerChunk` на 1 кадр.** `framesPerChunk = Int(Float(...) * 30 / secondsPerWindow)`, а `chunkIndices` усекает `Float(windowIdx) * strideInFrames` на каждое окно; для нецелой `strideInFrames` последний индекс может стать `== framesPerChunk` — out-of-bounds запись в :263. С реальной геометрией pyannote безопасно, но guard'а нет. Проверять границы последнего окна.

- **[P2] `ThirdParty/QwenASR/Sources/Qwen3ASR.swift:51-60` — `getFeatExtractOutputLengths` жёстко кодирует константы `100` и `13`, связанные с `n_window = 50`.** При гипотетическом `n_window ≠ 50` `chunkSize` разойдётся с формулой, `numAudioTokens` в prompt не совпадёт с `audioFeatures.dim(0)`, и `mergeAudioFeatures` (:826, `min(...)`) молча оставит лишние `<|audio_pad|>`-эмбеддинги — тихая деградация качества без ошибки. Параметризовать формулу или проверять `nWindow == 50` при загрузке.

- **[P2] `Qwen3ASR.swift:1029` — EOS-токены `[151645, 151643]` захардкожены в обход config/tokenizer.** При смене checkpoint'а с другим словарём молча ломается терминация: генерация упрётся в `maxTokens` и упадёт `incompleteGeneration` без видимой причины. Читать из `tokenizer_config.json` (как сделано в VibeVoice `VibeVoiceModel.swift:124-125`).

- **[P2] SpeakerKit (процесс): цепочка из 7 патчей и `upstream.json` не проверяется автоматически против снимка.** Ничего не мешает отредактировать `Sources/` напрямую без обновления патча — регресс-тесты тестируют поведение, а не происхождение; при обновлении upstream это ручная сверка 18 файлов. Как исправить: тест/скрипт, который применяет патчи из `upstream.json` к выкачанной ревизии и сравнивает SHA с рабочей копией (offline-вариант: сверка SHA уже применённой цепочки, зафиксировав итоговые хэши).

### Мелкое (P3)

- **[P3] `Qwen3ASR.swift:853-877` vs `Qwen3ForcedAligner.swift:295-315` — `preprocessAudio` скопирован дословно**; аналогично сплайс аудио-фичей (811-849 vs 253-287) и `fromModelDirectory` (1301-1351 vs 420-462). Внутри одного пакета свести в общие хелперы (межпакетное объединение как раз нарушать не нужно — «снимочность»).
- **[P3] `Qwen3ASR.swift:278-293` — мёртвый `createBlockAttentionMask`** (после переписывания энкодера на побочные окна не вызывается). Удалить.
- **[P3] `Qwen3ASR.swift:12` — неиспользуемый `import Hub`.**
- **[P3] `Qwen3ASR.swift:1297-1298`, `VibeVoiceModel.swift:186-187` — `as! [NSString: Any]` на JSON tokenizer-файлов** — повреждённый JSON крашит процесс вместо бросаемой ошибки (файлы закреплены SHA в worker, поэтому P3).
- **[P3] `VibeVoiceModel.swift:31-33, 200-201` — мёртвые `speechStartId`/`speechEndId`** (присваиваются, не читаются). Удалить или использовать.
- **[P3] `VibeVoiceModel.swift:165, 203` — дублированная проверка long-form checkpoint'а** в двух местах. Оставить одну.
- **[P3] `VibeVoiceModel.swift:47-49, 78` — `precondition`/`preconditionFailure` вместо бросаемых ошибок** (QwenASR в тех же ситуациях кидает ошибки). Привести к `VibeVoiceError`.
- **[P3] `Qwen3ForcedAligner.swift:431` — асимметрия API**: `fromModelDirectory` выравнивателя молча берёт tokenizer из `modelDir` (у Qwen3ASR — отдельный параметр), нигде не задокументировано.
- **[P3] `DiarizationChannel.swift:33-36` — `send` в закрытый канал бросает `CancellationError`** — семантически «канал закрыт», а не «задача отменена». Практического бага нет; ввести отдельный кейс или документировать.
- **[P3] `PyannoteDiarizer.swift:117-135` — `prepareSeekClips` стал мёртвым кодом** (patch отвергает непустые `clipTimestamps` до вызова). Пометить комментарием, чтобы при обновлении upstream не «оживили».
- **[P3] `PyannoteDiarizer.swift:303`, `SpeakerEmbedderModel.swift:43` — магическое `30` (chunkLengthInSeconds) дублируется** литералами; каноническое значение — `SpeakerSegmenterModel.chunkLengthInSeconds`. Свести к одной константе.
- **[P3] `DSP.swift:17, 28` — противоречивые дефолты periodic у окон** (hanning false, hamming true) и строковый `norm: String?` при enum `melScale`. Все call-sites явные, но дефолты провоцируют ошибку при переиспользовании.
- **[P3] `Qwen3ASR.swift:1081-1083, 1120-1122` — деление на `temperature` не влияет на результат** (декодер строго greedy) — создаёт ложное впечатление управляемости. Убрать или задокументировать как no-op.
- **[P3] `Qwen3ASR.swift:569` — неиспользуемый параметр `layerIdx`** (остаток от per-layer rope).
- **[P3] `Qwen3ForcedAligner.swift:172-176` — пустые секции `// MARK:` после удаления LIS-логики** — вводят в заблуждение.
- **[P3] `upstream.json` всех трёх пакетов не перечисляют локально добавленные файлы** (`QwenRuntimeError.swift`, `VibeVoiceError.swift`, `DiarizationChannel.swift`). Добавить поле `addedFiles`.
- **[P3] `SpeakerSegmenterModel.swift:352-354` — public convenience `init()` с `NoOpMLFeatureProvider` сохранён** — та же «тихая пустая output»-ловушка, которую выпилил inference-errors.patch. Удалить или пометить deprecated.

---

## 6. Скрипты, сборка, ресурсы

### Важное

- **[P1] `scripts/build_app.sh:18-57` — повторная сборка .app не удаляет старое содержимое.** `APP="$ROOT/dist/LocalScribe.app"` фиксирован, дальше только `mkdir -p` и `cp`/`ditto` поверх (в скрипте нет ни одного `rm -rf`). При обновлении зависимостей SwiftPM (переименованный/удалённый `*.bundle` или `*.metallib`) старые файлы остаются в `Contents/Resources`, повторно подписываются и молча уезжают в дистрибутив; `codesign --verify` это не ловит. Как исправить: `rm -rf "$APP"` перед `mkdir -p` или атомарная замена через `dist/LocalScribe.app.tmp`.

- **[P2] `scripts/media_pipeline_checks.py:5` и `media_failure_checks.py:6` — жёстко зашит путь worker** `.build/out/Products/Release/LocalScribeWorker`, при том что AGENTS.md предупреждает об этом пути, а README велит получать его через `swift build --show-bin-path`. Вычислять bin-path той же командой, что и build_app.sh:17.

- **[P2] `Resources/models.lock.json` — diagram-профили (`diagram-qwen3-vl-4b/8b/32b`) добавлены в каталог правкой без генератора** (коммит 39c1904; подтверждено `git show -S`): ~28,5 ГБ записей невозможно перепроверить или воспроизвести скриптом, в отличие от остальных семейств. Добавить `lock_diagram_models.py` по образцу qwen-генератора.

- **[P2] `scripts/lock_models.py:52-93` — самый слабый из трёх генераторов и небезопасная запись трекаемого файла.** (а) `write_text` не атомарно — обрыв в середине записи портит отслеживаемый каталог на 94 КБ (приложение само использует атомарную запись, `download_models.py` — temp+replace; здесь нет); (б) проверка полноты ловит только пустой список (qwen-генератор сверяет точное множество путей) — частичный ответ HF API пройдёт незамеченным; (в) нет `argparse`/`main()` — нельзя импортировать в тесты без сети. Исправить по образцу `lock_qwen_models.py`.

- **[P2] `build_app.sh:47` + `scripts/licenses.py:10-12` — упаковка зависит от побочных артефактов `build/`, создаваемых только build_ffmpeg.sh.** Если `Assets/tools` перенесены с другой машины, а `build/` пуст, упаковка упадёт посередине на `cp build/ffmpeg-sha256.txt` и трейсбеке licenses.py. Проверять sha-файл и каталог лицензий тем же условием, что и бинарники.

- **[P2] Нет единой точки входа для проверок / CI.** Рецепт существует только в AGENTS/README; `scripts/tests` не покрывает `build_app.sh`, `licenses.py`, `format_checks.py`, `lock_models.py`, `lock_vibevoice_models.py`, `smoke.py`, `media_*_checks.py`. Приоритет: (1) `scripts/verify.sh` — агрегатор build + test + python-тесты + проверка синхронности версий `Info.plist` ↔ `AppInfo.swift` ↔ README (сейчас 2.8.0/15/2.8.0 совпадают вручную); (2) тесты `build_app.sh` (фейковые swift/codesign в PATH, по образцу `test_build_ffmpeg.py`) и `licenses.py`; (3) GitHub Actions при появлении hosted-раннера macOS 26/Xcode 27.

### Мелкое (P3)

- **[P3] `scripts/package_source.sh:5-7` — выборочные exclude для Vendor**: любое новое содержимое `Vendor/` молча попадёт в tarball; одновременно не исключены `.agents/` и `ProjectReview-2026-10-24.md` — они уедут в публичный исходный архив (этот отчёт тоже стоит исключить). Exclude `Vendor/*` + re-include `ffmpeg-*.tar.xz`.
- **[P3] `Package.swift:16, 45-47` — Swift 6 для библиотек и тестов задан неявно** (дефолт tools-версии 6.1; фактические режимы подтверждены разбором `.build/manifest.pif`). Прописать `.swiftLanguageMode(.v6)` явно, чтобы смена дефолта тулчейна не перевернула режимы молча.
- **[P3] `Package.swift:17-28` — дублирование списков продуктов MLX** у `LocalScribeQwen` и `LocalScribeVibeVoice` (идентичные четыре продукта). Вынести в константу над манифестом.
- **[P3] `scripts/smoke.py:39-41` и `fault_checks.py:25, 29` — пути относительно CWD, а не корня репозитория** (нет ROOT-якоря). Запуск не из корня дает FileNotFoundError; smoke.py к тому же вырезает `pipelineVersion` из Swift-исходника регэкспом — смена форматирования ломает пробу.
- **[P3] `scripts/licenses.py:4` — нет проверки аргумента** (голый IndexError-трейсбек). Минимальный argparse.
- **[P3] `docs/ThirdParty.md:14-21` — таблица лицензий не упоминает адаптеры QwenASR/VibeVoiceASR**: их MIT-лицензии попадают в бандл под невнятным алиасом `Resources/Licenses/MLXAudio-MIT.txt` (побайтово совпадает с обоими). Добавить строки и копировать по имени.
- **[P3] `Resources/ModelService-Info.plist:6` — CFBundleVersion застрял на 1 при версии приложения 15.** На работу не влияет; зафиксировать в release-чеклисте.
- **[P3] `scripts/external_codec_checks.py:9-11` — единственный сетевой скрипт без SHA-пина и ретраев** (контраст с build_ffmpeg.sh и lock-генераторами).
- **[P3] ~30 log-файлов в корне + хрупкий контракт `final-tests.log`** (`collect_measurements.py:24` читает по магическому имени). Параметр `--test-log` и/или соглашение `TestResults/last-xctest.log`.

---

## 7. Документация

### Важное

- **[P1] `docs/ASRBackendIntegration.md:8` — устаревшая версия пайплайна: «Новые задания используют `1.0.0-audio2-asr9-…`»** — фактически код (`Contracts.swift:98`), `ASRModels.md:121`, `Architecture.md:131` и AGENTS.md называют `…asr10…`. Разработчик, читающий документ по интеграции бэкендов, получает неверную версию. Исправить или явно пометить абзац историческим с датой среза.

- **[P1/P2] `README.md:88` — список доступных моделей расходится с каталогом.** «Whisper small/medium/large-v3-turbo/large-v3 и Qwen3.5 4B/9B/27B (4-bit)» — в каталоге 26 профилей: есть также Whisper base, Qwen3.5 2B, 9B-8bit, 27B-6bit/8bit, 122B-A10B и экспериментальные Qwen3-ASR/VibeVoice-ASR (задокументированы в ModelManagement и отображаются в настройках). Пользователь не узнаёт о них из README.

### Желательное (P2)

- **[P2] `docs/ASRContinuation.md:229` — неверный путь теста** (`Tests/LocalScribeTests/ASRWindowTests.swift` не существует; фактический — `Tests/LocalScribeDiarizationTests/ASRWindowTests.swift`); там же раздел «Карта реализации» (203-233) описывает `ASRRecognitionPolicy` в `SpeechRecognizer.swift`, хотя после рефакторинга политика — `WhisperRecognitionPolicy` в `WhisperASREngine.swift`.
- **[P2] Дословный дубль блока «Итог сессии 6» в 5 копиях**: `ASRWindowing.md:12-41` и `ASRMatrix.md:3-32` совпадают побайтово (проверено diff); те же числа в `ASRExperimentStatus.md`, `ASRContinuation.md:27-38`, `Acceptance.md:71-96`. Держать полный текст один раз в ASRExperimentStatus, в остальных — ссылки.
- **[P2] `docs/ProjectReview-2026-10-18.md` — ~75 ссылок вида `/Users/eugene/…/файл.swift:199`**: абсолютные машинозависимые пути не работают у другого пользователя и после сдвига строк. Привести к относительным (как в ProjectReview-2026-10-24).
- **[P2] `docs/MemoryAudit-2026-10-19.md:29, 77, 97` — 40 кликабельных ссылок в gitignored-каталог `../TestResults/`**: на чистом checkout все битые; оформить как код-спаны.
- **[P2] Нет указателя по docs/ (35 файлов)** — нет `docs/README.md`, разделяющего действующие normative-документы и замороженные отчёты сессий; пометки «Исторический этап» сделаны непоследовательно.
- **[P2] Нет архитектурной диаграммы** (mermaid/ASCII): Architecture.md — плотная проза без схемы компонентов GUI → WorkerSupervisor → worker → runs, XPC-загрузчика, архива.

### Мелкое (P3)

- **[P3] `README.md:127` vs AGENTS.md — рассинхрон команды тестов** (без `--force-resolved-versions`).
- **[P3] `README.md:5-7` — «Текущая версия 2.8.0», следом заметка «В версии 0.1.1 исправлена…»** — забытая историческая вставка в верхнем блоке.
- **[P3] `docs/MicrophoneFix.json` — файл-сирота** (нигде не упоминается).
- **[P3] `ProjectReview-2026-10-24.md` в корне, собратья — в docs/** — непоследовательное размещение ревью-документов (этот отчёт положен в корень по прецеденту 10-24; при наведении порядка стоит решить одно место для всех).
- **[P3] `docs/Acceptance.md:1` — заголовок «Отчёт по приёмке LocalScribe 0.1»** при актуальности матрицы и версии 2.8.0.
- **[P3] `docs/ModelManagement.md:39` — «Всего 16 профилей» (19.10)** — сейчас 26; датированные количества нигде не сведены к актуальному состоянию.
- **[P3] Нет глоссария терминов** («схема» vs «диаграмма», «реплика»/segment, «контрольная точка»/checkpoint, «допуск»/admission) — ~20 строк сняли бы дрейф.
- **[P3] Нет FAQ/troubleshooting для пользователя** (типовые сценарии восстановления размазаны по README и docs).

Позитив: версии AGENTS.md точно совпадают с кодом (проверено: pipeline, версии схем, 2.8.0/build 15, 589 XCTest, 63 python-теста, все упомянутые файлы существуют); все markdown-ссылки docs↔docs и docs→Sources разрешаются, кроме двух указанных файлов.

---

## 8. Горизонтальные темы

### 8.1 Асимметрия веток «записи/схемы» — главный систематический источник находок

Диаграммная ветка реализована позже и аккуратнее; улучшения не портированы обратно, а зеркальный код разошёлся. Конкретные примеры из находок выше:

| Улучшение в diagram-ветке | Отстаёт в аудио-ветке |
|---|---|
| tie-break сортировки по id (`DiagramRepository.swift:81`) | `Repository.swift:47`, `RecordingCoordinator.swift:88` |
| чтение ровно `size` байт pinned-файла (`DiagramRepository.swift:327-335`) | `ImportSource.swift:47-52` |
| фиксация снимка до модальной панели экспорта (`DiagramWorkspaceModel.swift:233-241`) | `AppModel.swift:1460-1465` |
| синхронный `start(provider)` в drop-обработчике + `onDiscard` | `AppModel.swift:487` |
| `onDrop` возвращает признак принятия | `RecordingDetailColumn.swift:131-133` |
| `delete` фильтрует in-memory без рескана | — (наоборот: у схем рескан, `DiagramCoordinator.swift:107-116`) |
| `pruneDeletedMembership` учитывает выемку группы | — (наоборот: у схем не учитывает, `DiagramCoordinator.swift:305`) |

Рекомендация: не копировать по одному, а извлечь generic-слой (`GroupStore`, `ArchiveState<ID, Manifest>`, общий sidebar-протокол, общий pinned-copy-хелпер) — тогда расхождения исчезнут классом, а не точечно. Это самая доходная инвестиция в сопровождаемость.

### 8.2 AppModel как god-object

1620 строк и ~10 ответственностей. Расшивка (диаграммная ветка, управление моделями, self-check'и — в отдельные типы) уменьшит поверхность рассуждений о гонках; queue/live-capture оставить в центре. Тесно связано с находкой тестов о прямых мутациях внутренностей AppModel — после расшивки появятся естественные точки тестирования.

### 8.3 Ресурсы на 3-часовых записях

Заявленный лимит «3 часа включительно» делает пиковую память воркера главной операционной темой: 691 МБ `[Float]` при диаризации (P2 выше), двойной PCM-декод в ASR-окнах, тысячи actor-хопов токенизации в SummaryEngine, квадратичные проверки evidence. Ни одно из них не блокер, но вместе они определяют поведение на длинных встречах; стоит добавить в `scripts/verify.sh` замер `ru_maxrss` воркера на синтетическом 3-часовом прогоне.

### 8.4 Отсутствие CI/единой точки входа

Единственный автоматический барьер — локальные 63 python-теста. Всё остальное (589 XCTest, сборка, упаковка, синхронность версий) — ручные команды из AGENTS/README. `scripts/verify.sh` (см. раздел 6) закрыл бы 80 % потребности до появления hosted macOS-раннера.

---

## 9. Приоритизированный план действий

### Быстрые победы (часы, без риска)

1. `build_app.sh` — `rm -rf "$APP"` перед сборкой (P1).
2. `ASRBackendIntegration.md` asr9→asr10; README — актуальный список моделей (P1).
3. ⌘⌫-предикат в `WorkspaceKeyboardShortcut` по образцу Esc (P2).
4. Guard'ы `deletingJobIDs` в `enqueueDiagram` (P2).
5. `try?` для записи метрик в `Worker.swift:83,106` (P2).
6. Tie-break сортировки в аудио-ветке; guard `== true` в `Repository.swift:96` (P3).
7. Убрать force-unwrap'ы: `Models.swift:280`, `Media.swift:217`, `Service.swift:30`, `Worker.swift:134`, `SummaryEngine.swift:54` (P2-P3).
8. Термогейт после ветки готового чекпойнта в `LiveTranscriber` (P2).
9. `capture-run.json` — проверка schemaVersion (P2).
10. Двойной скан тишины в `QwenASREngine` (P2).

### Среднесрочно (дни)

11. SHA-валидация Whisper/диаризации/итогов перед загрузкой в `Pipeline.performStage` (P1) + тест на «подменённый после установки файл».
12. Перенос паттерна `DroppedFileURL.start` в `importProviders` записей + `onDiscard` (P1).
13. Замена sleep-ассертов на детерминированные барьеры в ProcessingQueueTests (P1); унификация `waitUntil` и a11y-хелперов в один TestSupport.
14. Тесты: ModelDownloadClient (requestID/отмена), DiagramImageRegions (лимиты/EXIF/sequence), LiveTranscriber (цикл ожидания), SummaryEngine (оркестрация).
15. Ограничение чтения по size в `ImportSource`; фиксация снимка экспорта записей до `runModal`.
16. `verify.sh` + тесты `build_app.sh`/`licenses.py`; ROOT-якоря в smoke.py/fault_checks.py; `lock_diagram_models.py`; починка `lock_models.py` (атомарность, сверка множества).
17. Документация: указатель docs/README.md, дедупликация «Итога сессии 6», архитектурная диаграмма, глоссарий.

### Долгосрочно (недели, планировать отдельно)

18. Стриминг PCM окнами в диаризацию вместо 691 МБ массива (требует адаптера в SpeakerKit-снимке).
19. Generic-слой для веток записей/схем (`GroupStore`/`ArchiveState`, общий sidebar) — устраняет ~64 % дублирования sidebar'ов и ~90 строк зеркальных хелперов на координатор.
20. Расшивка AppModel (DiagramQueueController, ModelManagementController, self-check).
21. Автосверка патчей SpeakerKit с upstream.json (`addedFiles`, SHA цепочки).
22. Явные `.swiftLanguageMode(.v6)` в Package.swift и аудит Sendable-границ (`ASRMetricsRecorder`, Combine sink) к будущей миграции worker на Swift 6.
23. CI (GitHub Actions) при появлении hosted macOS 26/Xcode 27; до этого — pre-push-хук с verify.sh.

---

## Приложение: покрытие ревью

| Область | Файлов | Строк | Прочитано |
|---|---|---|---|
| Sources/LocalScribeCore | 25 | ~4 300 | все полностью |
| Sources/LocalScribe | 30 | ~5 800 | все полностью (AppModel частями) |
| Sources/LocalScribeWorker + ModelService + CWorkerIsolation | 22 | ~3 000 | все полностью |
| Tests (3 target'а) | 73 | ~17 000 | все полностью |
| ThirdParty (SpeakerKit, QwenASR, VibeVoiceASR) | 46 | ~9 100 | все полностью |
| scripts + Package.swift + Resources + .gitignore | ~50 | ~4 000 + ресурсы | все bash/py полностью; крупный probe_asr_matrix.py — структура; models.lock.json — программная проверка структуры |
| docs + README + AGENTS.md | 37 | ~6 600 | normative-документы полностью; ASRExperimentStatus/ASRContinuation/ASRMatrix — частично (исторические разделы) |

Проверено исполнением: `swift build -c release -j 4 --force-resolved-versions` — успешно, предупреждений нет; `python3 -m unittest discover -s scripts/tests` — 63 теста, 0 ошибок. Тесты XCTest не запускались (ревью только для чтения; статус по AGENTS.md на 09.11.2026 — 589 XCTest, 0 ошибок).

Спотовая перепроверка ключевых P1-находок перед публикацией выполнена независимо от агентов-ревьюеров (`AppModel.swift:487`, `ASREngine.swift:17-19`, `ProcessingQueueTests.swift:172`, `build_app.sh` — отсутствие `rm -rf`).
