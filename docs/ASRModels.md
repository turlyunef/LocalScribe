# Qwen3-ASR и VibeVoice-ASR

Состояние интеграции: 26.10.2026. Новые движки предназначены для готовых записей.
Качество на независимых встречах не принято. Профили не получают автоматическую
рекомендацию; опубликованные GPU-бенчмарки не используются как оценка Mac.

## Первичные источники и checkpoints

[Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), upstream
`7278e1e70fe206f11671096ffdd38061171dd6e5`: Apache-2.0, 16 кГц mono,
ASR/определение языка, включая русский и английский. Модель сама по себе
не выдаёт word timings. [ForcedAligner-0.6B](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B),
`c7cbfc2048c462b0d63a45797104fc9db3ad62b7`: Apache-2.0, alignment 11 языков,
включая RU/EN, вход до 5 минут; дискретность предсказания 80 мс. Он выравнивает
предложенный текст и не доказывает правильность распознавания.

В LocalScribe используются MLX-конверсии с той же исходной BF16 точностью
и отдельно 8-bit варианты, а не Python/PyTorch runtime. Точные файлы, размеры
и SHA-256 каждого файла перечислены в `Resources/models.lock.json`.

| Профиль / зависимость | Repository | Ревизия |
| --- | --- | --- |
| asr-qwen3-1.7b-bf16 | mlx-community/Qwen3-ASR-1.7B-bf16 | e1f6c266914abc5a46e8756e02580f834a6cf8a7 |
| aligner-qwen3-0.6b-bf16 | mlx-community/Qwen3-ForcedAligner-0.6B-bf16 | 53c8c0e46733eec430e4b53dd6471d0e5dee45f8 |
| asr-qwen3-1.7b-8bit | mlx-community/Qwen3-ASR-1.7B-8bit | a8379a2e2f9e313c9292cdf1af4055ab56d50d55 |
| aligner-qwen3-0.6b-8bit | mlx-community/Qwen3-ForcedAligner-0.6B-8bit | 0e1a68e91d815300c7c9754b2a7639378b23db15 |

`tokenizer-qwen3` закреплён на BF16 ASR-репозитории: vocab/merges/added tokens
совпадают с 8-bit. Aligner содержит свой tokenizer_config с timestamp-токеном.
Новый `scripts/lock_qwen_models.py` берёт metadata только по указанным ревизиям,
не скачивает LFS-веса и не заменяет уже закреплённый профиль. Общий генератор
каталога сохраняет отдельно добавленные backend-профили.

[VibeVoice-ASR](https://huggingface.co/microsoft/VibeVoice-ASR), upstream
`d0c9efdb8d614685062c04425d91e01b6f37d944`: MIT, long-form ASR, 24 кГц mono,
структурированные текст/таймкоды сегментов/speaker IDs; RU/EN входят в 51 язык
карточки. Upstream заявляет до 60 минут / 64K контекста. Это отдельный ASR
checkpoint, не VibeVoice TTS и не ASR-Streaming. Нативная Swift-реализация
существует в закреплённом commit SDK; Python MLX не считается её заменой.
Кандидат конверсии: `mlx-community/VibeVoice-ASR-4bit`,
`a1a15cb6c7b70f76b588af7e12f6fab34d5ab654`; отдельный tokenizer
`Qwen/Qwen2.5-7B`, `d149729398750b98c0af14eb82c78cfe92750796`.

## Runtime и ограничение ресурсов

[SDK Qwen v0.1.3](https://github.com/Blaizzy/mlx-audio-swift/tree/d302a5c6080d2bb97bae38c7418f82abb76013b6)
требует `mlx-swift-lm >=3.31.3`. В приложении сохранены **2.31.3** и MLX
**0.31.6**: подключены узкие отслеживаемые исходники `ThirdParty/QwenASR`
и `ThirdParty/VibeVoiceASR`, без обновления runtime итогов. VibeVoice и
акустические исправления Qwen взяты из
[commit 6fd9386](https://github.com/Blaizzy/mlx-audio-swift/tree/6fd938669e45412f5c35e011e7086ecd20397dbd).
README/upstream.json каждого снимка описывают локальные изменения и исходные SHA.
SDK не содержит сетевой загрузки, HTTP-сервера, Python и печати текста.

Qwen: core до 28 с, граница на первой паузе ≥600 мс после 2 с, реальный контекст
по 250 мс; доступный конец/originMs всегда ограничивают чтение. Энергия
используется для границы, не для доказательства тишины. Пропускается только
цифровой ноль. Короткий хвост сохраняется. ASR — greedy/autodetect/1024 токена
на окно, без перевода и без принудительного языка всей записи. RU/EN и
переключение языков выравниваются одним space-language tokenizer.

ASR+aligner одновременно занимают RAM; заявленный рабочий объём включает оба
набора весов, активации, KV, audio buffers и контекст. Qwen BF16: RAM от 16 ГиБ,
рабочий бюджет 10 ГиБ; 8-bit: от 16 / 7 ГиБ. Это консервативная политика,
а не измеренный максимум длинной встречи. MLX cache ограничен 256 МиБ,
memory limit — бюджетом RAM/Metal с системным резервом. После этапа worker
завершается, освобождая модели перед глобальной диаризацией/итогами.

VibeVoice: первый адаптер принимает всю запись до **300 000 мс** одним запросом.
Более длинная запись отклоняется до подготовки/ASR; независимые части,
склейка speaker IDs и молчаливое обрезание запрещены. Resampling 16→24 кГц
выполняется непрерывно с проверкой длины и положения импульса. Prefill 256,
greedy/8192 токена; незавершённый decode не публикуется. Segment timings не
становятся word timings. SpeakerKit остаётся единственным источником
глобальных участников. Фоновый режим обоих новых движков закрыт; Whisper
продолжает поддерживать закрытые CAF, seal/SHA/PCM прежним путём.

## Результаты и ошибки выравнивания

Проверяются соответствие всех слов исходному тексту, число timestamp-классов,
конечные значения, диапазон доступного аудио, начало ≤ конец и монотонность
начала/конца. Обратное время, выход за границу и несовпадение текста завершают
часть ошибкой. Исправления LIS/интерполяция SDK удалены. При только нулевой
длительности отдельного слова, свойственной сетке 80 мс, допустим проверенный
ненулевой общий диапазон сегмента: весь его слой `words` удаляется, текст
сохраняется и worker сообщает предупреждение. Диапазон берётся из настоящих
первого/последнего raw endpoints; длительности слов не придумываются.

Принадлежность контекста определяется серединой raw word interval. IDs частей
назначает Pipeline; checkpoint сохраняется только после успешного полного
запроса и проверки отмены. Код числовой диагностики различает backend и политику;
исторические Whisper encoder/decoder поля не заполняются эквивалентами Qwen.

## Закрепление и совместимость

Четыре обязательных `modelIDs` сохранены. ASR-профиль ссылается на необязательный
`alignerID`; RunInfo дополнительно закрепляет `auxiliaryModelIDs["aligner"]`.
`pinned(to:)` проверяет точный состав, отсутствие лишних зависимостей и общий
fingerprint с ID/revision/SHA backend/политики/aligner. Изменение выбора в UI
не переписывает уже созданный run. Установка/докачка проверенных частей,
импорт из папки и XPC download остаются общими для каждого компонента.

Версия новых заданий: `1.0.0-audio2-asr9-live1-diarization4-summary16`.
Готовые старые результаты читаются. Несовместимое продолжение сохраняет
active/pending/checkpoints и объясняет необходимость «Обработать заново».
Fingerprint SummaryEngine включает fingerprint Transcript; prompt summary16
и веса модели итогов не менялись.

## Проверка и статус качества

Артефакты текущей сессии — игнорируемая папка
`TestResults/qwen-integration-20261026`. Независимого нового эталона нет.
Исторические 511 слов уже раскрыты и используются только как регрессия.
Раздельная приёмка терминов, тишины/шума, наложений, потери целых реплик,
перевода и реальных word timings требует нового размеченного набора.
Технические RU/EN fixtures и fake SDK тесты не доказывают качество встреч.


## Повтор opt-in проверок

После обычной release-сборки запустить тестовый процесс с явным `deny network*`.
SDK-вывод фильтровать в памяти; не сохранять stderr, который может содержать речь.

- `QwenRuntimeTests/testLocalQwenFixture`: `LOCALSCRIBE_QWEN_ASR`,
  `LOCALSCRIBE_QWEN_ALIGNER`, `LOCALSCRIBE_QWEN_WAV`; это raw single-call probe
  без production-окон, отдельно измеряющий ошибочное alignment/перевод.
- `QwenPipelineFixtureTests/testPinnedLocalQwenOfflineCheckpointAndResume`:
  `LOCALSCRIBE_QWEN_LIBRARY` с каталоговыми именами компонентов,
  `LOCALSCRIBE_QWEN_VARIANT=bf16|8bit`, `LOCALSCRIBE_QWEN_WAV`.
  Проверяет реальные SHA, фабрику, bounded scheduler, checkpoint и повтор.
- `VibeVoiceASREngineTests/testLocalLongFormCheckpoint`:
  `LOCALSCRIBE_VIBEVOICE_MODEL`, `LOCALSCRIBE_VIBEVOICE_TOKENIZER`,
  `LOCALSCRIBE_VIBEVOICE_WAV`; только указанный long-form 4-bit checkpoint.

Без перечисленных переменных тесты явно пропускаются. Необязательные
`LOCALSCRIBE_QWEN_OUTPUT` / `LOCALSCRIBE_VIBEVOICE_OUTPUT` разрешают технические
артефакты (включая текст) только в отдельном игнорируемом каталоге TestResults.
Они не используются production worker. Тесты не скачивают и не устанавливают
модели, не работают с пользовательским архивом и не читают эталон в inference.


Frontend дополнительно сверён с [WhisperFeatureExtractor transformers 4.57.6](https://github.com/huggingface/transformers/blob/v4.57.6/src/transformers/models/whisper/feature_extraction_whisper.py):
удаляется последний центрированный STFT frame до mel/log/global clipping,
как требует используемый [Qwen3ASRProcessor](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/core/transformers_backend/processing_qwen3_asr.py).
Эта проверка отделена policy `rawalign-v2` от ранних технических прогонов v1.


## Проверка 26.10.2026

**Обычная эксплуатация Qwen пока не принята; все новые ASR-профили
экспериментальные.** VibeVoice опубликован как `asr-vibevoice-4bit` вместе
с `tokenizer-vibevoice`; его UI-политика требует 32 ГиБ RAM / 20 ГиБ рабочего
бюджета и ограничивает запись пятью минутами. Нативный checkpoint реально
проверен на коротком техническом примере. Предельный контекст на Mac с 32+ ГиБ
пока не измерен. Whisper остаётся автоматически рекомендуемым backend.

Комплект ASR+tokenizer(+aligner), без общих SpeakerKit/LLM: Qwen BF16 —
5 920 663 053 байта; Qwen 8-bit — 3 744 169 497; VibeVoice 4-bit —
5 725 481 634. Все файлы имеют точные ревизии, размеры и SHA в каталоге.

| Проверка | Результат |
| --- | --- |
| Release build, `--force-resolved-versions` | Успешно, прежние MLX 0.31.6 / LM 2.31.3 |
| Все XCTest | **474**, 0 ошибок, 15 штатных opt-in пропусков |
| Core / UI-service / worker | 179 / 151 / 144 |
| Python unittest | **63**, 0 ошибок |
| Аудиоформаты, включая AAC ADTS | **8/8** |
| Реальные прежние Whisper/SpeakerKit регрессии | **3/3**, deny network, SHA источников сохранён |
| Whisper live: checkpoint / EOF / resume / seal / PCM | Успешно, прежняя часть не переписана, хвост до 40 125 мс, checkpoint hit 1, новых вызовов ASR при resume 0 |
| Qwen BF16 и 8-bit: реальная фабрика / checkpoints / resume | Оба проходят короткий RU→EN→RU пример, 6 сегментов / 45 word timings; checkpoint SHA сохранён, новых вызовов при resume 0 |
| VibeVoice 4-bit: нативный checkpoint | 3 сегмента RU→EN→RU, без word timings / model speaker IDs |

Измерения на физическом **Apple M1 / 16 ГиБ, macOS 27.0.1, Swift 6.4**, mono PCM16 / 16 кГц,
**22,2435625 с** технического RU→EN→RU-аудио. Числа — отдельные наблюдения,
не контролируемый cold/warm benchmark: кэши, нагрузка и порядок различаются.
Qwen использует конечные окна, VibeVoice — один long-form запрос.

| Runtime | Load SDK, с | ASR, с | Alignment, с | Пик MLX allocations, ГБ (10⁹ байт) |
| --- | ---: | ---: | ---: | ---: |
| Qwen BF16 + BF16 aligner, policy v2 | 6,69 | 11,56 | 2,29 | 6,76 |
| Qwen 8-bit + 8-bit aligner, policy v2 | 5,27 | 8,78 | 2,40 | 4,58 |
| VibeVoice-ASR 4-bit | 4,39 | 36,77 | — | 6,42 |

Qwen полный этап с проверкой SHA занял 25,88 / 19,90 с. Load SDK в таблице
не включает SHA-проверку файлов. Пик MLX — счётчик allocations движка;
он **не равен суммарной unified memory/RSS UI/worker/системных служб**.
VibeVoice-проба короткого входа на M1 не подтверждает весь пятиминутный бюджет
и не снимает UI-ограничение от 32 ГиБ. Исходный BF16 VibeVoice (около 17,35 ГБ
одних весов) на M1/16 ГиБ не запускался; сравнения его качества с 4-bit нет.

На прежней реальной встрече **266,078 с** оба Qwen-комплекта остановились
на строгой проверке raw alignment, без публикации частичного transcript.
Уточнённая причина для 8-bit — timestamp вне доступного окна. Повторы после
исправления последнего STFT frame подтвердили отказ. WER нового готового
transcript отсутствует, потому что готовый transcript не получен. Исторический
Whisper large-v3 на этом источнике: WER 34,64% (S=125, D=38, I=14, N=511),
с той же NFKC/casefold/ё→е нормализацией. Это прежний раскрытый эталон,
не новый holdout и не свежий сравнительный прогон качества всех моделей.

При одиночном raw вызове Qwen на всём коротком mixed-примере наблюдались
перевод/повтор русских фраз и некорректные времена; production-окна по паузам
проходят техническую проверку. Это показывает зависимость от контекста,
не доказывает исправление перевода на встречах. Качество RU, EN, переключений
внутри фразы, терминов, шума/тишины и overlap на независимом наборе,
потеря целых реплик, word-timing gold и DER **ещё не приняты**.

Полные машинные отчёты, исходные SHA, logs и явные технические transcript
артефакты находятся только в `TestResults/qwen-integration-20261026`.
Установленная `.app`, подпись и пользовательский архив не обновлялись.
Чистая Metal-сборка, целевая macOS 26, GUI/TCC, физический микрофон,
сон/давление памяти и длинная реальная встреча требуют отдельной приёмки.


Дополнительно VibeVoice прошёл общую `ASREngineFactory` по опубликованному
каталогу с проверкой всех файлов/SHA: 28,56 с теста (5,81 с проверка+загрузка,
22,66 с распознавание/преобразование), тот же пик MLX 6,42 ГБ и три RU→EN→RU
сегмента. Это отдельный повтор при другом состоянии кэшей; его нельзя смешивать
с constructor-only load из таблицы как контролируемую оптимизацию.
