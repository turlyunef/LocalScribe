# Локальный Qwen3 runtime

Узкий снимок MIT-кода `Blaizzy/mlx-audio-swift`, `v0.1.3`,
`d302a5c6080d2bb97bae38c7418f82abb76013b6`. Исходные SHA файлов —
`upstream.json`. Это исходники target `LocalScribeQwen`, не сетевой SDK.

Из `6fd938669e45412f5c35e011e7086ecd20397dbd` перенесены DSP и исправления
акустического frontend: целочисленное деление длин, полная ширина padding
conv stem, Slaney mel scale и periodic Hann. Последние две настройки также
применяются к ForcedAligner: обе модели используют WhisperFeatureExtractor.
Дополнительно по transformers 4.57.6 WhisperFeatureExtractor удаляется последний
центрированный STFT frame **до** mel/log/clipping; CPU-тест проверяет число
frames, цифровую тишину и длины audio tokens на границе 100 frames.
Совместимость сохраняется с MLX 0.31.6 / MLXLMCommon 2.31.3.

Локальные изменения:

- Удалены Hub/network loaders, запись tokenizer.json, stdout-диагностика,
  detached streams и длинный автоматический splitter.
- BPE строится в памяти из закреплённых vocab/merges/tokenizer_config.
- Только явные имена весов; никакого сканирования дополнительных safetensors.
- Один greedy decoder с отменой на prefill/каждом токене. Отсутствие EOS,
  лимит токенов и repetition backstop завершаются ошибкой без частичного текста.
- ForcedAligner возвращает сырые классы времени. Удалены LIS, интерполяция
  и исправление монотонности; проверяется точное число классов.
- RU/EN alignment токенизирует Unicode whitespace; ASR определяет язык каждого
  конечного окна самостоятельно. Тексты и времена проверяются в адаптере worker.

Настройки окон и проверка coarse/word timings находятся в QwenASREngine.
Модель не получает эталон и не исправляет транскрипцию после alignment.
