# Диаграммы архитектуры LocalScribe

Набор PlantUML-диаграмм для быстрого погружения в проект. Все имена типов и
поведение соответствуют коду на момент 11.11.2026. Изменения в 2.11.2 описаны
в [записи PCM16](../CapturePCM16.md) и [снимке SpeakerKit](../../ThirdParty/SpeakerKit/README.md).

| Файл | Что показывает |
| --- | --- |
| [01-architecture.puml](01-architecture.puml) | Процессы (GUI, worker, XPC), модули, границы изоляции сети и диск. С чего начать. |
| [02-capture-recording.puml](02-capture-recording.puml) | Запись: разрешение, захват звука, пул буферов и writerQueue, 10-секундные CAF, фоновое ASR, финализация. |
| [03-queue-worker.puml](03-queue-worker.puml) | Общая очередь заданий, барьеры допуска, JSONL-протокол supervisor ↔ worker, исходы этапа (completed/failed/cancelled/64). |
| [04-worker-audio-pipeline.puml](04-worker-audio-pipeline.puml) | Внутренности worker: проверки задания и стадии prepare → ASR (offline/live, движки) → диаризация → итоги. |
| [05-diagram-recognition.puml](05-diagram-recognition.puml) | Ветка схем: ImportQueue, дедупликация SHA, «Ожидает модель», DiagramEngine (области, VLM, коррекция, экспорт). |
| [06-storage-data.puml](06-storage-data.puml) | Данные на диске: manifest против index.json, groups.json, артефакты runs/, акторы-координаторы, ResultReading/ResultEditing. |
| [07-recording-lifecycle.puml](07-recording-lifecycle.puml) | Состояния записи/схемы: пути к completed, паузы, отмена, повтор и продолжение. |

Рендер (нужен [PlantUML](https://plantuml.com) и Graphviz `dot`):

```bash
java -jar plantuml.jar -charset UTF-8 -tsvg docs/diagrams/*.puml
```

или открывать `.puml` напрямую в IDE с плагином PlantUML.
