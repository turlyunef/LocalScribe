# Сторонние компоненты

Исходные зависимости полностью закреплены в Package.resolved. Их лицензионные тексты копируются из checkout в Resources/Licenses при сборке.

SpeakerKit собирается из отслеживаемого снимка Argmax OSS 1.1.1 с локальным
исправлением дополнения хвоста, как модуль `LocalScribeSpeakerKit`.
Ревизия, исходные SHA-256, diff и порядок обновления — [ThirdParty/SpeakerKit](../ThirdParty/SpeakerKit/README.md).
Его `LICENSE` и `NOTICES` также копируются в `.app` из репозитория.

| Компонент | Лицензия / источник |
|---|---|
| Argmax OSS 1.1.1 (WhisperKit, SpeakerKit, встроенные производные swift-transformers) | MIT и уведомления NOTICES в исходном пакете; https://github.com/argmaxinc/argmax-oss-swift/tree/v1.1.1 |
| MLX Swift LM 2.31.3 | MIT, https://github.com/ml-explore/mlx-swift-lm/tree/2.31.3 |
| MLX Swift / MLX | MIT, точная ревизия в Package.resolved |
| Whisper Core ML / OpenAI Whisper | MIT, https://huggingface.co/argmaxinc/whisperkit-coreml ; https://github.com/openai/whisper |
| Токенизаторы openai/whisper-large-v3 и openai/whisper-small | Apache-2.0 согласно карточкам HF, закреплённые JSON только |
| SpeakerKit Core ML | CC BY 4.0. Атрибуция: Argmax, Inc., SpeakerKit Core ML, https://huggingface.co/argmaxinc/speakerkit-coreml . Веса не изменены; используются варианты W8A16 и W32A32. https://creativecommons.org/licenses/by/4.0/ |
| Qwen3.5 4B / 9B / 27B, MLX-конвертации | Apache-2.0. Qwen Team и mlx-community: https://huggingface.co/mlx-community/Qwen3.5-4B-4bit ; https://huggingface.co/mlx-community/Qwen3.5-9B-4bit ; https://huggingface.co/mlx-community/Qwen3.5-27B-4bit . Веса не изменены. |
| FFmpeg 8.0.1 | LGPL 2.1 or later; сборка без GPL/nonfree/внешних кодеков. https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz ; SHA-256 05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41 |

FFmpeg поставляется отдельными исполняемыми файлами, не статически слинкован с приложением. Соответствующий исходный архив сохраняется в Vendor и включается в исходный дистрибутив скриптом package_source.sh вместе с конфигурацией и скриптом сборки. Можно заменить исполняемые файлы своей совместимой сборкой и переподписать личный app bundle. Уведомления FFmpeg отображаются командами ffmpeg -L и -buildconf.

Модели скачиваются отдельно от .app. Их размеры, immutable revisions и контрольные суммы — Resources/models.lock.json. Перед публичным распространением проверить полноту лицензионного комплекта всех вложенных библиотек и модельных карточек; локальная ad-hoc подпись не является Developer ID/notarization.
