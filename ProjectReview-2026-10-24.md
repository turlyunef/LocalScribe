# Ревью LocalScribe — 24 октября 2026

## Объём и достоверность

Проверено чистое рабочее дерево на коммите `1f12cfd` (docs: update guidance for recording groups and title search). Это повторное полное ревью после [ProjectReview-2026-10-18](docs/ProjectReview-2026-10-18.md): сверены все 17 прежних находок и проаудирован новый код, появившийся с той даты (группы записей, поиск по названиям, импорт AAC ADTS, ASR-пробы и границы транскрипции, переработка sidebar/очереди импорта). Объём: ~20 200 строк Swift вне ThirdParty, 224 отслеживаемых файла.

Метод: Core/хранение, GUI/очередь и снимок SpeakerKit разбирали субагенты; worker/ASR/summary и безопасность/упаковку/скрипты проверены напрямую; ключевые находки перепроверены по коду (все выборочные сверки сошлись). Исходники, ресурсы и пользовательский архив не изменялись; сборки не выполнялись, кроме штатных тестовых прогонов.

Обозначения доказательств:

- **По коду** — прослежена конкретная цепочка выполнения; частота и стоимость на реальных встречах не измерялись.
- **Исполнено** — воспроизведено отдельной проверкой. В этом ревью исполнением подтверждена только побайтовая гигиена снимка SpeakerKit (обратное применение патчей во временной копии вне репозитория); остальные находки — «по коду». Часть статусов старых находок опирается на их приемочные тесты, прошедшие в текущем прогоне.

**P0/P1** — критический инцидент или скрытое повреждение данных; таких находок нет. **P2** — существенная ошибка корректности или расхода ресурсов. **P3** — оптимизация или укрепление границ с узкими условиями проявления. Приоритет не является CVSS-оценкой.

Всего новых находок: **2 P2, 13 P3**. Плюс одна незакрытая P2 предыдущего ревью (R06) и задокументированные блокеры качества сессии 6 (не дефекты кода).

| Приоритет | Пункты | Основные последствия |
| --- | --- | --- |
| P1 | — | — |
| P2 | **R06** (осталось), **N01** | ~2 GiB лишних копий аудио при диаризации длинных встреч; «Пересоздать итоги» принимает непроверенный транскрипт |
| P3 | N02–N14 | Граничные случаи целостности, молчаливые отказы UI, лишний I/O, латентные trap'ы на повреждённых метаданных |

## Статус находок ревью 18 октября 2026

| № | Суть | Статус |
| --- | --- | --- |
| R01 | Ошибки диаризации скрывались, частичный результат публиковался как готовый | **Исправлено** |
| R02 | Импорт symlink не создавал независимый оригинал | **Исправлено** |
| R03 | Чтение результата обходило проверки целостности | **Исправлено** (остатки → N03, N06) |
| R04 | Отмена зависала после выхода leader-процесса | **Исправлено** |
| R05 | Отсутствие backpressure segmenter→embedder | **Исправлено** |
| R06 | Несколько полных копий аудио при диаризации | **Не исправлено** (осознанно отложено, см. ниже) |
| R07 | «Продолжить» меняло закреплённые модели и создавало новый run | **Исправлено** |
| R08 | Пересборка длинного результата на MainActor по meter/status | **Исправлено** |
| R09 | Вопросы с поздними ответами оставались «открытыми» в финале | **Исправлено** |
| R10 | Проверка оснований без планирования контекста срывала summary | **Исправлено** |
| R11 | Чтение/скачивание моделей без предела по каталожному размеру | **Исправлено** |
| R12 | Rescan архива на каждом сохранении, O(N²) recover | **Исправлено** (остатки → N05, N07) |
| R13 | Повторная токенизация хвоста для каждого finding | **Исправлено** |
| R14 | Неограниченный параллельный импорт из drop | **Исправлено** (остаток → N13) |
| R15 | Symlink в model.partial писал за пределы models | **Исправлено** |
| R16 | Bootstrap считал пустую папку готовой моделью | **Исправлено** |
| R17 | SHA архива FFmpeg не подтверждал фактически собираемое дерево | **Исправлено** |

16 из 17 закрыты, большинство — с приемочными тестами, прошедшими в текущем прогоне (см. «Проверки и ограничения запуска»). Ключевые доказательства по закрытым пунктам:

- **R01/R05:** `predictChunks` — throwing task group, ошибка inference выходит наружу без частичной публикации ([SpeakerSegmenterModel.swift:185-211](ThirdParty/SpeakerKit/Sources/SpeakerKit/Pyannote/SpeakerSegmenterModel.swift), [Pipeline.swift:113-126](Sources/LocalScribeWorker/Pipeline.swift)); канал `DiarizationChannel` ёмкости 1 без потерь ([DiarizationChannel.swift:11-119](ThirdParty/SpeakerKit/Sources/SpeakerKit/Pyannote/DiarizationChannel.swift)); покрытие — InferenceFailureTests (12) и BackpressureTests (7).
- **R02:** импорт через закреплённый FD с `O_NOFOLLOW`, повторный SHA копии ([ImportSource.swift](Sources/LocalScribeCore/ImportSource.swift)); ImportTests покрывают symlink/подмену/FIFO.
- **R03:** единый проверяющий путь чтения [ResultReading.swift:7-79](Sources/LocalScribeCore/ResultReading.swift) (fingerprint, диапазоны, evidence, арифметика индексов ограничена); ResultReadingTests.
- **R04:** групповой SIGTERM→SIGKILL независимо от leader, дожидание обоих readers ([WorkerSupervisor.swift:114-138](Sources/LocalScribe/WorkerSupervisor.swift)); stubborn-child сценарии в WorkerSupervisorTests.
- **R07:** resume проверяет закреплённые `modelIDs` с SHA через `catalog.pinned(to:)`, а не текущий выбор ([Repository.swift:113-135](Sources/LocalScribeCore/Repository.swift)); ProcessingQueueTests:657-735.
- **R08:** `ActivityIndicators` вне AppModel, кэш рендера по ревизии/вкладке/формату, async-применение ([ResultPresentation.swift](Sources/LocalScribe/ResultPresentation.swift)); ResultPresentationTests (300 тиков meter не дают рендера).
- **R09:** `SummaryQuestionResolution` читает все поздние группы, вердикт требует verbatim-цитату и ID ([SummaryAnalysis.swift:154-190](Sources/LocalScribeCore/SummaryAnalysis.swift), [SummaryEngine.swift:131-147](Sources/LocalScribeWorker/SummaryEngine.swift)).
- **R10:** страницы проверки планируются точной токенизацией обоих вариантов промпта, повторная проверка перед каждым запросом, деление реплики на диапазоны символов ([SummaryVerification.swift:87-138, 201-213](Sources/LocalScribeCore/SummaryVerification.swift)).
- **R11:** expectedSize из каталога в каждом download callback и в финале ([Models.swift:104-177](Sources/LocalScribeCore/Models.swift), [Service.swift:34](Sources/LocalScribeModelService/Service.swift)).
- **R12:** координатор держит снимок, коалесцирование записи индекса, recover одним пакетом ([RecordingCoordinator.swift:63-100](Sources/LocalScribeCore/RecordingCoordinator.swift)); RepositoryPerformanceTests.
- **R13:** токены реплик предвычислены один раз ([SummarySourceIndex.swift:11-52](Sources/LocalScribeWorker/SummarySourceIndex.swift)).
- **R14:** один слот ImportQueue для drop/open panel/дублей ([ImportQueue.swift](Sources/LocalScribe/ImportQueue.swift)); ImportQueueTests (50 providers, максимум одновременных = 1).
- **R15:** каталоговые дескрипторы `openat` + `O_NOFOLLOW`, захват partial через `renameatxnp(RENAME_EXCL)` с проверкой inode ([ModelDirectory.swift:32-174](Sources/LocalScribeCore/ModelDirectory.swift)); ModelInstallerBoundaryTests (11 сценариев).
- **R16:** полная проверка size/SHA каждого файла до публикации, атомарный каталог ([download_models.py:25-91](scripts/download_models.py)).
- **R17:** извлечение в приватный staging с SHA-проверкой копии, дерево пользователя не переиспользуется ([build_ffmpeg.sh:12-19](scripts/build_ffmpeg.sh)).

## P2 — существенные дефекты

### N01. «Пересоздать итоги» принимает транскрипт активного run без сверки fingerprint и перештамповывает его

**Группа:** целостность данных. **Доказательство:** по коду.

**Где:** [Repository.swift:93-104](Sources/LocalScribeCore/Repository.swift) (ветка `summaryOnly` в `beginRun`); усиливается [Pipeline.swift:67-73](Sources/LocalScribeWorker/Pipeline.swift) (этап `.summarizing` читает `transcript.json` вообще без сверки fingerprint — в отличие от `.diarizing`, который проверяет `transcript.fingerprint == info.fingerprint` в [Pipeline.swift:104-106](Sources/LocalScribeWorker/Pipeline.swift)).

**Что не так и когда проявляется.** При создании summary-only run транскрипт читается напрямую из каталога активного run: `Disk.read` → структурная `validate(durationMs:)` → `transcript.fingerprint = info.fingerprint` (перештамповка) → запись в новый run. Исходный fingerprint никогда не сверяется с `RunInfo` активного run; `diarization.json` копируется вовсе без проверок. Если `transcript.json` завершённого run повреждён или подменён, отображение через `results()` честно откажет, но «Пересоздать итоги» молча примет чужое содержимое, присвоит ему валидный fingerprint нового run и построит итоги по нему — повреждение «отмывается» в валидный результат без предупреждений. Это прямой разрыв контракта «проверять fingerprint перед использованием результатов», исполняемого всеми остальными путями чтения (`results()`, `saveResultEdits` — [ResultEditing.swift:69](Sources/LocalScribeCore/ResultEditing.swift)).

**Почему важно.** Единственный оставшийся вход в архив, которому доверяет и GUI, и worker без проверки целостности. Требует уже повреждённого/подменённого файла (диск, ручное редактирование), поэтому P2, а не P1.

**Что переделать.** В `beginRun(summaryOnly:)` читать `RunInfo` активного run и требовать `transcript.fingerprint == activeInfo.fingerprint` (и `activeInfo.sourceHash == manifest.sha256`) до копирования; в Pipeline `.summarizing` добавить ту же проверку, что у `.diarizing`.

**Приёмка.** Структурно валидный транскрипт с чужим fingerprint в активном run → `beginRun(summaryOnly:)` возвращает понятную ошибку, новый run не создаётся; валидные legacy-, summaryOnly- и постредактированные run продолжают работать. Тестами не покрыто (в RunResumptionTests/ResultReadingTests этого сценария нет).

### R06 (осталось). Диаризация заранее создаёт несколько полных копий аудио

**Группа:** память, производительность. **Доказательство:** по коду и расчёту размеров; статус подтверждён, осознанно отложено — [DiarizationBackpressure.md:27-28](docs/DiarizationBackpressure.md) прямо выводит это из scope фиксов R01/R05.

**Где:** [Media.swift:171-182](Sources/LocalScribeCore/Media.swift) (полный WAV в `AVAudioPCMBuffer` + копия в `[Float]` — ~659 MiB на трёхчасовой mono/16 kHz), [PyannoteDiarizer.swift:173](ThirdParty/SpeakerKit/Sources/SpeakerKit/Pyannote/PyannoteDiarizer.swift) (полное материализование seek clip `Array(audioArray[...])` — ещё одна полная копия), [SpeakerSegmenterModel.swift:173-183](ThirdParty/SpeakerKit/Sources/SpeakerKit/Pyannote/SpeakerSegmenterModel.swift) (заранее созданный массив всех перекрывающихся chunks: при fullRedundancy ~414 блока × 1,92 MiB ≈ 795 MiB на 3 часа).

**Почему важно.** Порядка ~2 GiB конечных временных копий до ML-outputs и весов моделей на одной длинной встрече. Ограничение очереди (фикс R05) этот предел не снимает; на Mac с 16 ГБ в сочетании с весами ASR/диаризации это создаёт memory pressure и риск отмены анализа. Это не утечка — копии освобождаются, но пик расхода реален.

**Что переделать.** Ленивая выдача диапазонов chunks вместо предварительного массива; убрать полное копирование seek clip; затем рассмотреть bounded чтение PCM из файла. Сохранить побитово входы модели, stride, отражение хвоста и единую глобальную кластеризацию (независимая кластеризация частей запрещена — меняет идентичность участников).

**Приёмка.** Вход каждого блока и таймкоды неизменны (границы 480000 ± 1, stride ± 1); замер peak RSS по этапам до/после; DER и полнота интервалов на эталоне не ухудшаются. R06 чинить отдельно от R05 — ограничение очереди уже сделано.

## P3 — оптимизации и укрепление границ

### N02. Проверка ответов на открытые вопросы не планирует страницы для original-контекста

**Где:** [SummaryEngine.swift:344-371](Sources/LocalScribeWorker/SummaryEngine.swift) (`checkQuestionResolution`); единственная проверка — `count + 512 <= 8192` в :356. Контраст: `checkEvidence`/`checkAmendment` страницируют по точной токенизации ([SummaryVerification.swift:87-138, 201-213](Sources/LocalScribeCore/SummaryVerification.swift)).

**Что не так.** Промпт = кандидат + `original` (±2 соседа каждого evidence) + later-группа ≤ 3500 токенов. Группировка допускает отдельную реплику до ~3500 токенов ([SummaryAnalysis.swift:84-88](Sources/LocalScribeCore/SummaryAnalysis.swift)), а `original` собирает до 5–9 сегментов без бюджета — на транскрипте с крайне длинными репликами (включая ручные правки: ResultEditing сохраняет длинные сегменты) сумма превысит лимит, и после всей extraction упадёт весь summary с «Превышен контекст проверки ответа на открытый вопрос». Отказ явный, не тихий, поэтому P3.

**Что переделать.** Применить тот же `ReviewPrompt.pages` к `original`; сохранить обязательность цитаты и ID. **Приёмка:** mock tokenizer + длинные соседние реплики → все запросы в лимите, summary завершается; поведение на обычных транскриптах не меняется.

### N03. Preview ожидающего run не замечает дыр в нумерации ASR-чекпоинтов

**Где:** [ResultReading.swift:49-62](Sources/LocalScribeCore/ResultReading.swift). Проверяются дубликаты индексов и границы, но не связность: удалённый (не повреждённый) `asr/part-k.json` даёт «валидный» предпросмотр, молча теряющий 5-минутное окно. Финал не затронут (требует `transcript.json`). **Направление:** `sorted(indices) == Array(0..<count)`. Тестов нет.

### N04. groups.json накапливает membership удалённых записей

**Где:** [RecordingCoordinator.swift:151-165](Sources/LocalScribeCore/RecordingCoordinator.swift) — `delete` не трогает каталог групп; чистка есть только при удалении группы ([RecordingGroups.swift:77-83](Sources/LocalScribeCore/RecordingGroups.swift)). Корректность не нарушена (удаление группы корректно блокируется существованием папки записи — :237-241, покрыто тестом), но авторитетный каталог растёт неограниченно и хранит UUID удалённых встреч. **Направление:** удалять membership в той же транзакции после успешного удаления папки либо GC в `recover`. Тестов нет.

### N05. Массовое удаление группы перезаписывает index.json после каждой записи

**Где:** [RecordingCoordinator.swift:233-234](Sources/LocalScribeCore/RecordingCoordinator.swift) — цикл `delete`, каждый `delete` делает `scheduleIndex(); flushIndex()` (:161-164). Для группы из M записей — M полных записей индекса всего архива на потоке actor; частично возвращает нагрузку, от которой избавился фикс R12. Компромисс осознанный (комментарий «Avoid retaining deleted metadata»), manifest остаётся источником истины, поэтому P3. **Направление:** один flush в конце пакетного удаления. Тестов на кратность записи индекса нет.

### N06. Повреждённый manifest.json делает запись невидимой без диагностики

**Где:** [Repository.swift:33-37](Sources/LocalScribeCore/Repository.swift) — `list()` через `compactMap { try? load(...) }` молча пропускает битые элементы. Аудио и артефакты остаются на диске, но запись исчезает из UI и `recover()` без сообщения (для groups.json есть `groupsError`, для manifests аналога нет). Старая приёмка R03 требовала «ошибочный элемент изолировать и показывать понятную ошибку». **Направление:** отличать мусор от повреждённой записи; для второй — placeholder/ошибка рядом с `groupsError`. Прямого покрытия `list()` нет.

### N07. Дедупликация импорта сканирует весь архив на каждый файл

**Где:** [Repository.swift:53](Sources/LocalScribeCore/Repository.swift) — `list().first(where: { $0.sha256 == digest })` на каждый импорт: пакетный drop из K файлов даёт K полных сканов манифестов (остаточная форма R12). Координатор уже держит снимок с SHA, но репозиторий им не пользуется. **Направление:** передавать множество SHA из координатора либо вести хэш-индекс рядом с index.json (производные данные). Тестов нет.

### N08. TOCTOU между probe и закреплением дескриптора импорта — спорное

**Где:** [RecordingCoordinator.swift:144-146](Sources/LocalScribeCore/RecordingCoordinator.swift) — `AudioInfo` (длительность/каналы) получен по пути до `ImportSource` open. Подмена файла именно в этом окне даст манифест с `durationMs`, описывающим другое содержимое. Последствия самоликвидируются: worker `Media.prepare` перепроверяет архивный оригинал, `Transcript.validate` отклонит рассогласование — задание упадёт с ошибкой, не тихо. **Направление:** сверять размер по fstat после открытия с наблюдавшимся при probe; при расхождении перезапускать probe по закреплённому дескриптору. Тестов нет; вероятность низкая.

### N09. Копирование/экспорт нескешированного раздела или Markdown строится синхронно на MainActor

**Где:** [AppModel.swift:1048-1053](Sources/LocalScribe/AppModel.swift), [ResultPresentation.swift:92-100](Sources/LocalScribe/ResultPresentation.swift). `copy(part)` для раздела ≠ текущей вкладки и `export(markdown: true)` при промахе кэша идут в синхронный `render()` — полный проход по транскрипту; выбор сознательный (комментарий в коде). «Копировать → Всё» или «Экспорт → Markdown» на длинной встрече может дать заметный фриз (первый раз; затем кэшируется). **Направление:** прогревать соседние ключи после async-рендера либо рендерить в task и выставлять в pasteboard/файл по готовности с проверкой актуальности. Тестами не покрыто.

### N10. «Продолжить» молча ничего не делает, если manifest записи не читается

**Где:** [AppModel.swift:646](Sources/LocalScribe/AppModel.swift) — `guard let m = try? await archive.load(id) … else { return }`: при повреждённом manifest.json enqueue тихо выходит; кнопка выглядит активной, но не даёт ни действия, ни сообщения (сам `resume` свои ошибки показывает). Проявляется только на повреждённых элементах архива. **Направление:** различать ошибку чтения и невыполнение предусловий; первую показывать через errorHandler. Тестами не покрыто.

### N11. Повторный клик по той же ссылке-таймкоду не прокручивает текст

**Где:** [ContentView.swift:274-276](Sources/LocalScribe/ContentView.swift) — скролл только при `coordinator.target != targetID`, а `model.jumpTo` ([AppModel.swift:84](Sources/LocalScribe/AppModel.swift)) нигде не сбрасывается после применения. Пользователь прокрутил текст вручную и снова кликнул ту же ссылку обоснования — перехода нет. **Направление:** сбрасывать `jumpTo` после применения или сравнивать «запрошено ≠ применено». Тестами не покрыто.

### N12. Панель ошибок скрывается при потере фокуса приложения и не возвращается при активации

**Где:** [AppErrorHandler.swift:55](Sources/LocalScribe/AppErrorHandler.swift) — `hidesOnDeactivate = true`; повторный показ только при новом `report`/`dismiss`. Ошибка обработки, пришедшая, пока пользователь в другом приложении, остаётся невидимой в очереди до следующей ошибки. Для части заданий это единственная диагностика неудачи. **Направление:** при `NSApplication.didBecomeActiveNotification` вызывать `presentIfNeeded()` при непустой очереди. Тестами не покрыто.

### N13. ImportQueue: enqueue в окне размотки после cancel молча отбрасывается — остаток R14

**Где:** [ImportQueue.swift:11](Sources/LocalScribe/ImportQueue.swift) — `guard task?.isCancelled != true else { return }`: между `cancel()` и завершением Task новая подача теряется без сообщения. Окно существует только во время shutdown (единственный вызов `cancel` — AppModel.shutdown), поэтому P3. **Направление:** при отменённом слоте отвечать явной ошибкой «импорт отменяется». Частично покрыто косвенно.

### N14. Латентные trap/зависание на некорректных метаданных модели диаризации

**Где:** [PyannoteDiarizer.swift:321](ThirdParty/SpeakerKit/Sources/SpeakerKit/Pyannote/PyannoteDiarizer.swift) — `Int(chunkLength / windowLength)` при `windowLength == 0` даёт `Int(inf)` → trap; [SpeakerEmbedderModel.swift:63](ThirdParty/SpeakerKit/Sources/SpeakerKit/Pyannote/SpeakerEmbedderModel.swift) — при `windowsCount == 1` бесконечный цикл построения `chunkIndices`. Проявляется только с повреждённой/чужой моделью; в продукте модели закреплены SHA-256 и embedder обычно откажет раньше. Сбой должен быть ошибкой этапа, а не крахом worker. **Направление:** валидировать описание модели при загрузке и бросать ошибку. Тестами не покрыто.

## Мелкие замечания (вне приоритизации)

- [Service.swift:33](Sources/LocalScribeModelService/Service.swift): `URL(string:)!` — некорректная запись каталога крашнет XPC-сервис вместо ошибки; каталог отслеживается и генерируется lock_models.py, риск низкий.
- [SummarySourceIndex.swift:24](Sources/LocalScribeWorker/SummarySourceIndex.swift): `indexByID[$0.id]!` — силовое извлечение; безопасно для текущих вызовов (все сегменты происходят из того же транскрипта), но хрупко при будущих изменениях сигнатуры.
- [package_source.sh:5-7](scripts/package_source.sh): tar не исключает `build/` (ffmpeg-конфиги, копия Package.resolved) и включает `.git`; для «исходного» пакета это лишнее.
- SpeakerKit-снимок: multi-clip режим (`clipTimestamps`) смешивает шкалы клипов (upstream-поведение; LocalScribe всегда вызывает с одним клипом — недостижимо сегодня, стоит зафиксировать ограничение в README снимка); заявленная опция `minClusterSize` молча игнорируется кластеризацией.
- `RecordingSearch.deinit` трогает MainActor-состояние вне изоляции — безопасно в Swift 5-режиме таргета; отметить при миграции GUI на Swift 6.

## Известные блокеры качества — не дефекты кода, но ограничивают готовность

По [ASRExperimentStatus.md](docs/ASRExperimentStatus.md) (обновлено 22.10.2026), смена 6:

- Полная приёмка **не пройдена**. Остаются блокеры: лимит summary15 на исходной встрече, перевод русских реплик, смысловые ошибки/дубли итогов.
- WER на независимом эталоне 511 слов: offline 34,64 %, live raw 30,72 % / final 30,33 %. Это задокументированные ограничения качества моделей/промптов, а не регрессии кода; XCTest их не покрывает.
- Установленная `.app` после asr8 не обновлялась; чистая сборка Metal, подпись, TCC и многочасовая приёмка на реальных встречах в этом ревью не проверялись. Финальный эталон уже раскрыт — после настройки нужен новый независимый набор.

## Что проверено и подтверждено корректным

1. **Модель безопасности:** App — sandbox + audio-input + user-selected read-write, без сети; Worker — sandbox + inherit; ModelService — sandbox + network.client (единственный сетевой компонент). `CWorkerIsolation` перепроверяет запрет сети и жёстко падает при неудаче; XPC-сервис валидирует ID/индекс по встроенному закреплённому каталогу, передаёт FD после unlink временного файла, не получает архив/аудио/транскрипцию. Architecture.md соответствует коду.
2. **Упаковка:** build_app.sh проверяет demuxer `aac` и minos 26.0 у инструментов, копирует metallib к worker с отдельной подписью, иерархическая подпись вложенных компонентов, verify --deep --strict. licenses.py собирает лицензии SwiftPM-зависимостей, FFmpeg (LGPL), SpeakerKit (MIT/NOTICES) и Resources/Licenses.
3. **Worker lifecycle:** JSONL v1 — команда в stdin, WorkerEvent только в протокольный stdout (dup до перенаправления в stderr), EOF → групповая отмена, watchdog родителя, дожидание обоих readers; SDK stderr дренируется без сохранения.
4. **Транскрипция:** границы окон (offline 300 с / core 28 с / live 30 с), уважение `originMs`/доступного конца, проверка отмены после возврата SDK, prefix retry с реальным контекстом без сдвига таймкодов; экспериментальные флаги (gap recovery, context review, word repair) выключены в production и не применяются к Transcript.
5. **Итоги:** страницы проверки планируются точной токенизацией с учётом обоих attempt'ов, повторная проверка перед каждым запросом, verbatim-цитаты и ID обязательны, вопросы закрываются только явным поздним ответом, конфликтные поправки → uncertain, ручные итоги без evidence — только для проверенной ручной версии.
6. **Хранение:** атомарный `Disk.write`, монотонная ревизия транзакций координатора, группы (`groups.json` v1, «Без темы» всегда последняя, повреждённый каталог блокирует изменения), импорт через закреплённый FD с повторным SHA, AAC ADTS с переполнениями/лимитом 10 801 с/границей 3 часов, live capture (seal/SHA/PCM, только закрытые CAF, непрерывность окон, лимит 1081 фрагмент).
7. **Снимок SpeakerKit:** побайтово равен upstream `1bbc57cb` + 3 патча (сверено обратным применением во временной копии, 18/18 SHA); отражение только неполного хвоста без изменения реальных длин; единая глобальная кластеризация голосов.
8. **Согласованность метаданных:** версия 0.38.0 в README/Info.plist/AppInfo; `pipelineVersion = 1.0.0-audio2-asr8-live1-diarization4-summary15` в [Contracts.swift:97](Sources/LocalScribeCore/Contracts.swift) совпадает с документацией; entitlements/Info.plist (экспорт внутренних UTI как `public.data`, NSMicrophoneUsageDescription) соответствуют AGENTS.md.
9. **Прогоны:** XCTest — 407 тестов (171 Core + 143 UI/service + 93 worker/диаризация), 0 ошибок, 11 пропусков (8 модельных/probe, 2 нативных DnD, 1 поисковый бенчмарк) — совпадает с AGENTS.md; Python-тесты скриптов — 59/59.

## Рекомендуемый порядок исправления

1. **N01** — закрыть дыру целостности summaryOnly: маленькое точечное изменение, добавить приёмочный тест.
2. **R06** — память диаризации: замерить peak RSS на длинном аудио, ленивые chunks, убрать копию seek clip; отдельно от уже сделанного R05.
3. **N02** — постраничное планирование original-контекста в проверке вопросов.
4. **Диагностика/UX:** N10, N12, N06, N03, N04 — молчаливые отказы и невидимые состояния пользователь видит без объяснений.
5. **Производительность без изменения качества:** N05, N07, N09.
6. **Укрепление границ:** N14, N08, N13 и мелкие замечания.

Каждый пункт пригоден для отдельной задачи: содержит причину, сценарий, область изменений и критерии приёмки. До реализации сверить номера строк с текущим деревом. Изменения схемы хранения/entitlements/подписи не входят в автоматическое разрешение — следовать AGENTS.md и конкретному поручению.

## Проверки и ограничения запуска

- `swift test -c release -j 4 --force-resolved-versions` — exit 0: LocalScribeTests 171/171, LocalScribeUITests 143 (3 пропуска), LocalScribeDiarizationTests 93 (8 пропусков), 0 ошибок. Прогоны выполнены в этой сессии на текущем дереве.
- `python3 -m unittest discover -s scripts/tests` — 59 тестов, 0 ошибок.
- Не проверялись: sandbox/TCC и настоящий микрофон, установленная `.app`/подпись/Gatekeeper, чистая сборка Metal, WER/DER и трёхчасовая приёмка на реальных встречах, Instruments/Allocations. Зелёный прогон не покрывает сценарии N01–N14 — тесты на них отсутствуют.
- Организационное: субагенты ревью Core/GUI/SpeakerKit завершились успешно; запуски субагентов по безопасности/упаковке и worker/ASR дважды прерывались сетевыми ошибками провайдера — эти области проверены основным агентом напрямую (все файлы прочитаны полностью, ключевые утверждения сверены по коду); сводка по безопасности выше опирается только на непосредственно прочитанное.
