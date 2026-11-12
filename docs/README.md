# Документация LocalScribe

## Устройство и контракты

- [Архитектура](Architecture.md) и [диаграммы](diagrams/README.md)
- [Запись в PCM16](CapturePCM16.md), [фоновое распознавание](LiveCapture.md) и [жизненный цикл worker](WorkerLifetime.md)
- [Управление моделями](ModelManagement.md), [профили ASR](ASRModels.md) и [интеграция движков](ASRBackendIntegration.md)
- [Группы](RecordingGroups.md), [спецификация поиска](RecordingTitleSearchSpec.md) и [реализация поиска](RecordingTitleSearch.md)
- [Результаты и экспорт](ResultRendering.md), [распознавание схем](DiagramRecognition.md) и [очистка ресурсов](ResourceCleanup.md)
- [Сторонние зависимости](ThirdParty.md)

## Проверки и история

- [Матрица приёмки](Acceptance.md), [ручная проверка на Mac](MacAcceptance.md) и [измерения](Measurements.json)
- [Эксперименты ASR](ASRExperimentStatus.md), [матрица](ASRMatrix.md), [оконный алгоритм](ASRWindowing.md) и [передача работы между сессиями](ASRContinuation.md)
- [Начало записи в ASR](ASRPrefixFix.md), [хвост диаризации](DiarizationTailFix.md) и [ограничение очереди диаризации](DiarizationBackpressure.md)
- [Измерения памяти](MemoryAudit-2026-10-19.md), [проверка моделей](StartupHashMemory.md), [репозиторий](RepositoryPerformance.md), [буферы захвата](CaptureWriterAllocations.md) и [итоги](SummaryPerformance.md)
- [Ревью 18.10](ProjectReview-2026-10-18.md), [ревью 24.10](../ProjectReview-2026-10-24.md), [исправления 24.10](ProjectReviewFixes-2026-10-24.md) и [ревью 09.11](../ProjectReview-2026-11-09.md)
