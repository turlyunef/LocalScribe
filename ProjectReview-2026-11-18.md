# Аудит багов и уязвимостей LocalScribe — 18.11.2026

Полный аудит кода на дефекты и уязвимости: все 124 Swift-файла `Sources/` (~29 тыс. строк, включая Core, GUI, worker, XPC-сервис и WhisperHints), 23 Python-скрипта и 9 shell-скриптов `scripts/` (~4,4 тыс. строк), плейлисты, entitlements и CI-воркфлоу. Каждая находка проверена чтением кода и сопровождена ссылкой на файл и строку; две самые серьёзные (крэш `Range` в обезличивании, невалидированный `runId` в `Repository`) дополнительно верифицированы повторным чтением кода вручную. Изменения в код не вносились, сборки и тесты в этом прогоне не запускались (задача — статический анализ).

## Резюме

Критических уязвимостей (выполнение кода, утечка данных наружу, обход sandbox) **не найдено**. Сильные стороны проекта подтверждены: цепочка загрузки моделей (пиннинг URL → лимит размера в полёте → двойной SHA-256 → атомарная публикация через staging с повторной проверкой), XPC-аудит по uid + cdhash пира, атомарные записи везде, отсутствие `shell=True`/`eval`/`pickle` в Python, сеть только у XPC-сервиса. Приватность выдержана: тексты обезличивания, подстановки, имена и словарь распознавания не попадают в события, метрики и логи.

Найдено **25 находок**: 1 высокого приоритета (аварийное завершение worker-процесса), 3 средних, 21 низкого. Общий рисунок: качество высокое, дефекты — точечные «мягкие» границы контрактов и редкие крэш-сценарии, которые тесты не покрывают.

### Находки по приоритету

| # | Проблема | Область | Приоритет |
|---|----------|---------|-----------|
| 1 | Фатальный крэш `Range` при неякорной строке модели в контекстном padding — worker падает по SIGTRAP без события `failed` | Worker | P1 |
| 2 | `bindLiveTranscript` строит пути из невалидированного `info.id` и читает/пишет файлы до проверки принадлежности — path traversal при подделанном манифесте | Core | P2 |
| 3 | `Int(NaN)` на не-конечных таймкодах WhisperKit — крэш расшифровки на дегенеративном аудио | Worker | P2 |
| 4 | Импорт текста читает весь файл в память до проверки лимита размера — memory pressure при случайном гигабайтном файле | GUI | P2 |
| 5 | Синхронный XPC-прокси в `cancel()` — ObjC-исключение на инвалидированном соединении | GUI | P3 |
| 6 | `cleanupTemporaryFiles` читает run.json по невалидированному `pendingRunId` | Core | P3 |
| 7 | TOCTOU в `retryAnonymization`: `updateCard` затирает успевшую уйти в очередь попытку | GUI | P3 |
| 8 | Пробел в «нейтральном» wrapper'е ошибок: сырой `localizedDescription` SDK уходит в событие `failed` | Worker | P3 |
| 9 | `deleteSelected` показывает настоящий `NSAlert` без тестового шва — зависание UI-теста | GUI | P3 |
| 10 | Ловушка пустой транскрипции в `SummarySourceIndex.evidenceContext` (`0...-1`) | Worker | P3 |

Остальные находки (P3): см. разделы ниже.

---

## Что проверено и подтверждено чистым (отрицательные результаты аудита)

Для контекста серьёзности — перечислены атаки, которые **проверены и не проходят**:

- **XPC-сервис моделей** (`Sources/LocalScribeModelService/Service.swift`): подключение ограничено одинаковым uid и pinned cdhash пира (проверка живого процесса через `proc_pidpath` + `SecCodeCopyGuestWithAttributes`); URL — только из закреплённого каталога со проверкой схемы/host/отсутствия query и fragment; размер enforced в полёте (`didWriteData`) и по факту; SHA-256 проверяется дважды на стороне установщика; TOCTOU между проверкой и публикацией закрыт атомарным `RENAME_EXCL` в приватный staging с перепроверкой; `O_NOFOLLOW`/`O_EXCL`/отказ от `..` по всему пути моделей.
- **Изоляция сети**: `network.client` есть только у XPC-сервиса; приложение — sandbox + audio-input + user-selected r/w; FFmpeg собран `--disable-network --enable-protocol=file,pipe`; ATS-исключений нет.
- **Приватность**: `WorkerEvent` несёт только типы/фиксированные сообщения/имена артефактов; метрики — только числа; словарь распознавания не попадает в ошибки (только счётчик токенов); stderr дренируется без сохранения; трассировка вывода моделей за двойным замком.
- **Протокол JSONL v1**: malformed JSON / неизвестный `kind` / версия ≠ 1 → код 64; EOF stdin → `cancelled` + `terminateGroup(72)`; смерть родителя → watchdog 71; SIGPIPE игнорируется; утечек fd нет (F_DUPFD_CLOEXEC + defer close); отмена ждёт обоих pipe-reader'ов.
- **Целостность архива**: `Disk.write` везде атомарный с ISO 8601; повреждённые каталоги групп не перезаписываются пустыми; публикация результатов только для текущей RUNNING-попытки с совпадающим `expected_result_revision_id`; `pipelineVersion` проверяется в конструкторе Pipeline для любой стадии; чекпоинты сверяются по fingerprint; LSB-побайтовое сравнение PCM в `CaptureIntegrity.verify`.
- **Shell/Python-скрипты**: нет `curl|sh`, `shell=True`, `os.system`, `eval`/`exec`, `pickle`, `yaml.load`; все загрузки pinned SHA-256 из репозитория; `mktemp` с шаблоном; переменные квочены; subprocess — списками аргументов; ID источников валидируются regex.
- **CI** (`verify.yml`): pinned SHA checkout, `persist-credentials: false`, `permissions: contents: read`, только офлайн-проверки.
- **Playback**: подавление повторного автоперехода после точной перемотки (допуск 50 мс) реализовано; границы пауз в секундах «начало включено / конец исключён»; `ffmpeg` запускается с `-protocol_whitelist file,pipe`; drag-типы валидируются как UUID.

---

## 1. Sources/LocalScribeWorker (30 файлов, ~5,9 тыс. строк) + WhisperHints

### [P1] AnonymizationEngine.swift:465 — фатальный крэш `Range` при неякорной строке в контекстном padding

```swift
let span = (window.lowerBound + range.lowerBound)..<(window.lowerBound + range.upperBound)
// Context padding belongs to the neighbouring core; ...
let clamped = Swift.max(core.lowerBound, span.lowerBound)..<(Swift.min(core.upperBound, span.upperBound))
```

`detect()` передаёт модели окно `withContext(core, padding: 96)` — вход модели включает 96 скаляров контекста вне core. `unanchoredLineRanges` приходят в координатах окна и переводятся в координаты документа. Если модель сообщила неякорное совпадение на строке, целиком лежащей в padding (модель видит эти строки — это её вход), пересечение `core ∩ span` пусто, причём `span.upperBound < core.lowerBound` — конструктор `max..<min` создаёт диапазон с `lowerBound > upperBound` → **fatal error «Range requires lowerBound <= upperBound», процесс падает по SIGTRAP**. Комментарий на строках 463–464 показывает, что автор рассчитывал на пустой clamp, но пустой Range не строится при пустом пересечении с «отрицательной» шириной. Тот же поток диапазонов идёт из рекурсивного сплита после `GenerationError.truncated` (AnonymizationRecognizer.swift:153–157).

Последствие: попытка обезличивания обрушивает worker без события `started → failed` (контракт события нарушен, карточка остаётся RUNNING до обнаружения смерти процесса супервизором). Вероятность не пренебрежимо мала: ~11% ширины окна — padding, неякорные отчёты — штатная ситуация, ради которой механизм построен. Верифицировано повторным чтением кода.

Исправление: проверять пересечение до конструирования:
```swift
guard span.lowerBound < core.upperBound, span.upperBound > core.lowerBound else { continue }
let clamped = Swift.max(core.lowerBound, span.lowerBound)..<Swift.min(core.upperBound, span.upperBound)
```

### [P2] WhisperASREngine.swift:239, 243, 246–247 — крэш `Int(NaN)` на не-конечных таймкодах

```swift
... readStart + Int($0.start * 1000) ...                    // слова
let midpoint = readStart + Int((s.start + s.end) * 500)     // сегмент без слов
... readStart + Int(s.start * 1000) ...
```

Таймкоды WhisperKit — `Double` из DTW-выравнивания, которое на дегенеративном аудио возвращает NaN/∞. `Int(NaN)` в Swift — фатальная ошибка «Double value cannot be converted to Int because it is either infinite or NaN», до клампа `max(0, min(durationMs, ...))` дело не доходит. Все три остальных движка эту угрозу закрывают (`GigaAMASREngine.swift:90` — `seconds.isFinite`, `QwenASREngine.swift:177` — `item.start.isFinite`, `VibeVoiceASREngine.swift:123` — `row.start.isFinite`); Whisper-адаптер — единственный без валидации. Верифицировано повторным чтением кода.

Последствие: расшифровка на Whisper обрушивает worker-процесс вместо `failed`-события на проблемном фрагменте аудио.

Исправление: отбрасывать слово/сегмент при `!start.isFinite || !end.isFinite` (как другие движки).

### [P3] Worker.swift:73 — «нейтральный» wrapper неполон: сырой `localizedDescription` уходит в событие `failed`

```swift
let safe = classified?.message ?? (error as? ScribeError)?.localizedDescription ?? "…нейтральное…"
```

Движки сознательно нейтрализуют тексты ошибок SDK (Pipeline.swift:188, DiagramEngine.swift:88, AnonymizationRecognizer.swift:231), но общий обработчик `failed()` пропускает `localizedDescription` любой ошибки вне `ScribeError`/`ClassifiedDiagnosticError`. Например, `AVAudioFile(forReading:)` (ASREngine.swift:107) бросает NSError с англоязычным текстом и путём файла. Утечки текста документа нет, но политика нейтральных сообщений нарушается: в UI-событие и diagnosticFailure попадает непереведённый SDK-текст/путь.

Исправление: пропускать к нейтральному сообщению всё, кроме `ScribeError`/`ClassifiedDiagnosticError`; Cocoa-ошибки заворачивать на месте бросания.

### [P3] SummarySourceIndex.swift:36 — ловушка пустой транскрипции

`max(0, index - 2)...min(transcript.segments.count - 1, index + 2)` при пустом массиве даёт `0...-1` → fatal «Range requires lowerBound <= upperBound». Сейчас недостижимо (Pipeline.swift:95–98 выводит пустую транскрипцию из сценария до SummaryEngine), но `SummaryEngine` — actor с публичным API, и любой новый вызов активирует ловушку. Дешёвый фикс: `guard !transcript.segments.isEmpty`.

### [P3] Защищённые force-unwrap на границах кодирования (информативно)

- `SummaryEngine.swift:114, 193, 217, 387` — `String(data: try encoder.encode(...), encoding: .utf8)!` (вывод JSONEncoder всегда валидный UTF-8);
- `VibeVoiceASREngine.swift:148, 161` — `input.floatChannelData![0]`, `source.baseAddress!` (непустота проверена на строке 139).

Крэш сегодня невозможен, но при рефакторинге инварианты легко теряются — `guard let` стоил бы дёшево.

### [P3] AnonymizationAssembly.swift:57–61 — O(n²) на сериях бэкслэшей

`isEscaped` пересканирует всю серию `\` перед каждым `[`/`<`; документ из длинных серий бэкслэшей и скобок даёт квадратичное время. Ограничено SIZE_LIMIT входа, поэтому низко. Фикс: предвычислить чётность экранирования одним проходом.

---

## 2. Sources/LocalScribeCore (40 файлов, ~7,5 тыс. строк)

### [P2] Repository.swift:186–207 — `bindLiveTranscript` строит пути из невалидированного `info.id` и читает файлы до guard принадлежности

```swift
let manifest = try load(id), path = run(id, info.id)            // путь строится до проверок
let captureInfo = try Disk.read(RunInfo.self, at: path.appendingPathComponent("capture-run.json"))
let seal = try Disk.read(CaptureSeal.self, at: path.appendingPathComponent("capture-seal.json"))
guard manifest.sourceComplete, manifest.pendingRunId == info.id, ... // проверка — после чтений
...
try Disk.write(transcript, to: path.appendingPathComponent("asr-transcript.json"))  // запись
try Disk.write(final, to: path.appendingPathComponent("run.json"))
```

`run(_:_:)` (Repository.swift:14) — прямое `appendingPathComponent(runId)`; `info.id` не проверяется как UUID до построения пути, а оба чтения (строки 187–188) происходят до guard. `RunInfo.init(from:)` (Contracts.swift:125–141) не валидирует формат `id`, и `Repository.save` не валидирует `pendingRunId`. Подделанный `run.json`/`manifest.json` с `"id": "../../…"` даёт чтение произвольного JSON-пути, а при прохождении guard'ов (подделанный `pendingRunId` с той же строкой) — и запись `asr-transcript.json`/`run.json` за пределы корня архива. Это нарушает собственную конвенцию кодовой базы: `ResultReading.validatedResults` (ResultReading.swift:39) прямо комментирует «Check before constructing a path from the persisted identifier», и `resumeRun` (Repository.swift:155) тоже проверяет. Текущий вызов из AppModel идёт после `resumeRun`, который валидирует id, так что практический эксплойт требует подмены данных на диске; тем не менее защита должна быть в самом репозитории. Верифицировано повторным чтением кода.

Исправление: `guard UUID(uuidString: info.id) != nil` первой строкой метода; в идеале — валидировать `pendingRunId` в `save`.

### [P3] Repository.swift:249 — `cleanupTemporaryFiles` читает run.json по невалидированному `pendingRunId`

```swift
let pending = manifest.pendingRunId.flatMap { try? Disk.read(RunInfo.self, at: run(id, $0).appendingPathComponent("run.json")) }
```

Тот же класс, что и находка выше, но read-only: подделанный манифест даёт чтение произвольного пути с разбором как RunInfo. Фикс: `UUID(uuidString:) != nil` перед построением пути.

### [P3] Contracts.swift:22–23 — недоступный `fileSize` трактуется как превышение размера

`fileSize` — `Int?`; при nil метаданных корректный маленький файл отвергается с вводящим в заблуждение «Файл JSON превышает допустимый размер» (повторная проверка `data.count` на строке 25 всё равно есть — nil стоило бы пропускать). Аналогично Contracts.swift:50–51: `volumeAvailableCapacityForImportantUsage ?? 0` — недоступная метрика тома даёт ложное «Недостаточно свободного места» на любом импорте.

### [P3] Export.swift:23–31 — неполное Markdown-экранирование экспорта расшифровки

`clean(_:markdown:)` экранирует `\ * _ [ ] < > # |`, но не backtick и не `-`/`+`/цифру-с-точкой в начале строки; `Transcript.validate` не запрещает переводы строк внутри `segment.text`, значит внутренняя строка реплики, начинающаяся с `-` или `1.` или содержащая backtick, меняет структуру Markdown-документа (список, code span). Это не XSS (HTML-экспорта нет), но непоследовательно с более строгим `DiagramExport.escapeMarkdown`/`singleLine` (DiagramExport.swift:62–68, 196–202). Фикс: гасить переводы строк сегмента в пробел и экранировать backtick.

### [P3] AnonymizationCoordinator.swift:144–157 — `editSource`/`editResult` не блокируются на QUEUED/RUNNING попытке

Координатор сериализует транзакции, но не запрещает правку во время RUNNING-попытки — инвариант держится только на UI (AnonymizationCardEditor блокирует панели). Если правка пройдёт, публикация упадёт на `result.validate(sourceScalarCount:)` (AnonymizationContracts.swift:443–445 сверяет пары с текущим source, а не с замороженным входом), и карточку придётся обрабатывать заново. Стоит либо guard в `editSource`, либо трансформация пар относительно замороженного входа при публикации.

### [P3] Единичные force-unwrap, защищённые предусловиями (информативно)

`Localization.swift:75, 82` (статически валидный regex-литерал и гарантированные цифры capture group), `ModelDirectory.swift:54` (`parts.last!` — пустой путь крэшнет, но все вызовы после `validatePaths()`), `Models.swift:326` (`child(create: true)!` — не-nil гарантирован контрактом). Формально противоречат политике zero-force-unwrap; самозащита стоила бы дёшево.

---

## 3. Sources/LocalScribe — GUI (54 файла, ~15,7 тыс. строк)

### [P2] AnonymizationWorkspaceModel.swift:269–273, 317–332 — импорт текста читает весь файл в память ДО проверки лимита

`importCandidate` вызывает `Self.readImportBytes(url)` (строка 269), который внутри `Task.detached` выполняет `ImportSource(url).readBytes()` — с `data.reserveCapacity(Int(size))` и чтением файла целиком. Проверка лимита (`if let limit = model.anonymizationImportLimitBytes, UInt(bytes.count) > limit`) выполняется только после полного чтения (строка 271). При отсутствии назначенного профиля модели `anonymizationImportLimitBytes == nil` и проверка не выполняется вовсе (отказ придёт только на admission или по `maximumCardBytes` ≈ 48 МБ при коммите — уже после чтения). Показательно, что путь restoration в этом же файле проверку ДО чтения имеет (строки 324–326).

Последствие: пользователь роняет в окно «Тексты» переименованный большой файл — приложение целиком читает его в память (detached-таск не спасает от потребления RAM): memory pressure, swap, риск джетсам всего процесса при активной записи микрофона.

Исправление: сверять `ImportSource.size` с `max(limit, AnonymizationInputLimit.maximumCardBytes)` до `readBytes()` (как в `forRestoration`).

### [P3] ModelDownloadClient.swift:63 — синхронный XPC-прокси в `cancel()` бросает на инвалидированном соединении

`connection?.remoteObjectProxy` — синхронный прокси без error handler. Между крахом XPC-сервиса и выполнением `invalidationHandler`'ом (`connection = nil`) остаётся окно, в котором отправка сообщения бросает ObjC-исключение → крах приложения. `cancel()` зовётся в том числе из `close()` при shutdown и из `cancelInstall()`. Фикс: `remoteObjectProxyWithErrorHandler` (как в `fetch`).

### [P3] AppModel.swift:2940–2969 — TOCTOU в `retryAnonymization`: `updateCard` затирает успевшую уйти в очередь попытку

Между `loadCard` (guard «не queued/running», строка 2947) и `textArchive.updateCard` (строка 2960) есть await (`anonymizationReadiness`, строка 2957). Замыкание безусловно заменяет `card.latestAttempt` новой WAITING_MODEL-попыткой. Если за это окно параллельный `wakeWaitingTextCards` успел перевести попытку в QUEUED — retry затрёт её, `processTextJob` молча вернёт слот (guard на строке 2625 не пройдёт), и карточка зависнет в «Ожидает модель» до следующего изменения readiness. Данные не теряются, но задание выпадает из очереди. Фикс: guard в замыкании `updateCard` на совпадение id попытки (как в `enqueueText:2568`).

### [P3] AppModel.swift:2041–2047 — `deleteSelected` показывает настоящий `NSAlert` без тестового шва

Все остальные подтверждения вынесены в подменяемые обработчики, а `deleteSelected` создаёт `NSAlert` напрямую и зовёт `runModal()`. По конвенции проекта («Настоящий NSAlert в тестовом процессе вешает прогон») UI-тест, добравшийся до кнопки удаления записи, зависнет. Фикс: seam по образцу остальных.

### [P3] AppModel.swift:1033 — `sourceType` всегда `"microphone"`

`requestRecording` создаёт `Manifest(sourceType: "microphone", …)` даже при включённом только системном звуке (`microphone == nil, systemAudio == true`) — метаданные не отражают реальный источник, мешает диагностике и фильтрации архива.

### [P3] AppModel.swift:3078–3207 — dev self-check'и делают синхронный файловый I/O на MainActor

`microphoneSelfCheck`/`sandboxSelfCheck` (флаги `--self-check*`) выполняют `Disk.write`, `copyItem`, `Media.assembleCapture` синхронно на главном акторе — противоречит правилу модуля; при `--self-check-full` заметно замораживает UI. Dev-only, поэтому низко.

---

## 4. Скрипты, XPC-окружение, CI

### [P3] scripts/download_models.py:50–53 — нет лимита объёма при докачке

Цикл `while data := response.read(8*1024*1024): fp.write(data)` пишет столько, сколько пришлёт сервер; размер проверяется только после завершения потока (`valid_file`, строка 54). Swift-аналог (`ModelFileDownload.didWriteData`, Models.swift:275–283) обрывает загрузку при превышении — Python-скрипт при злонамеренном/сломанном CDN (206 на Range с бесконечным потоком) может забить диск до отказа. Фикс: прерывать чтение при превышении `file['size'] - n`.

### [P3] scripts/catalog_io.py:41–42, 35 — неограниченное чтение ответа в память и эвристика иммутабельности кэша

`get()` делает `response.read()` без ограничения размера и кэширует на диск без лимита (анормальный ответ уедет в память целиком). `immutable = "/resolve/" in url` (строка 35): любой URL с этим фрагментом кэшируется навсегда; при будущем вызове с именем ветки после `/resolve/` скрипт молча возьмёт застарелый кэш и закрепит его в models.lock.json. Фикс: лимит чтения и явный флаг `immutable`.

### [P3] scripts/smoke.py:41, 43 — пути к models.lock.json и Contracts.swift относительно CWD

`pathlib.Path('Resources/models.lock.json')` не привязаны к `ROOT`; при запуске не из корня скрипт успеет скопировать аудио и создать полусозданную запись в TestResults, затем упадёт с `FileNotFoundError`. Фикс: `ROOT / '…'`.

### [P3] scripts/licenses.py:4 — нет валидации аргумента, молчаливые коллизии имён

`sys.argv[1]` без проверки (без аргумента — IndexError); имена `package.name + '-' + source.name` при одинаковых именах пакетов молча перезаписывают друг друга — текст лицензии одного из пакетов может исчезнуть из общего файла. Фикс: argparse + проверка destination.

### [P3] scripts/format_checks.py:91 — неатомарная запись отчёта

`report.write_text(...)` напрямую, тогда как соседние проверки пишут атомарно через temp+replace; обрыв посреди записи оставит битый JSON в TestResults/format-checks.json.

### [P3] Diagnostics.swift:196 — молчаливая потеря журнала диагностики

`try? Disk.write(self.history, to: file)` — ошибка записи (диск полон, права) проглатывается без следа. Для best-effort осознанно, но единственный «тихий» `try?` на записи; стоил бы хотя бы `os_log`.

### [P3] probe_live_caption_comparison.py:196–199, probe_asr_matrix.py:261–264 — Markdown-инъекция в локальные отчёты

Тексты транскриптов вставляются в .md через отступ, который многострочный текст теряет на следующих строках — содержимое аудио может «выбраться» из блока и стать разметкой. Эксплуатация чисто локальная (TestResults). Фикс: code-fence ``` или экранирование переносов.

---

## Сводка по зонам

| Зона | Файлов прочитано | P1 | P2 | P3 |
|------|------------------|----|----|----|
| LocalScribeCore | 40 (~7,5 тыс. строк) | 0 | 1 | 5 (+3 информативно) |
| LocalScribeWorker + WhisperHints | 30 (~5,9 тыс. строк) | 1 | 1 | 3 (+2 информативно) |
| LocalScribe (GUI) | 54 (~15,7 тыс. строк) | 0 | 1 | 5 |
| Скрипты/XPC/CI | 23 py + 9 sh + 4 Swift + плейлисты + CI | 0 | 0 | 7 |

**Общий вывод.** Проект зрелый: дисциплина транзакций, атомарной записи, валидации схем/UUID/SHA и sandbox-изоляции последовательна по всем модулям; критических уязвимостей нет. Единственный P1 — крэш `Range` в обезличивании (рекомендуется исправить до следующего релиза: детерминированный фикс в одну строку). P2-находки — точечные дыры в контрактах (path construction по невалидированному id, NaN-таймкоды, чтение до лимита), каждая закрывается малым патчем без изменения архитектуры.
