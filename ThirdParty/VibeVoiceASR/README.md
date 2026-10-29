# Локальный VibeVoice-ASR runtime

Узкий MIT-снимок `Blaizzy/mlx-audio-swift`,
`6fd938669e45412f5c35e011e7086ecd20397dbd`; исходные SHA — `upstream.json`.
Target `LocalScribeVibeVoice` использует прежние MLX 0.31.6 /
MLXLMCommon 2.31.3. В локальном Qwen2 заменены ropeOffset/applyRotaryPosition
на прежний cache.offset/RoPE; не подключены новые типы KV compression SDK.

Сохранены long-form ASR acoustic/semantic encoders, connectors, Qwen2 decoder,
санитизация имён/форматов весов и prompt конкретного ASR-checkpoint.
TTS и Streaming checkpoints не включены. Удалены сетевые loaders, автоматическая
загрузка Qwen2.5 tokenizer, печать текста и detached generation streams.
Optional processor files с диска не читаются: используются только закреплённые config и tokenizer.
Локальный tokenizer обязателен; список safetensors передаётся явно из каталога.

Вместо молчаливого обрезания после 59 минут — ошибка при превышении локального
контекста 300 с. Prefill ограничен 256 токенами за шаг; greedy decode требует
EOS, проверяет отмену и отклоняет исчерпание 8192 токенов. Cache/модель принадлежат
одному последовательному вызову worker.

Адаптер worker выполняет непрерывный 16→24 кГц Core Audio resampling, строго
проверяет весь JSON и исходные таймкоды сегментов. Speaker IDs модели не
публикуются; глобальную диаризацию выполняет SpeakerKit. `words` остаётся пустым.
До проверки конкретного checkpoint рабочий профиль в каталоге не публикуется.
