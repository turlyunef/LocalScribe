# Аллокации очереди записи микрофона

Этот отчёт относится к прежнему сохранению Float32 на частоте устройства.
После перехода на [PCM16 / 16 кГц](CapturePCM16.md) writer содержит постоянный
конвертер и три рабочих буфера; числа аллокаций ниже не характеризуют новую версию.
Скрипт probe использует текущий writer, поэтому повторный профиль даст другие результаты.

Проверено 18–19 октября 2026 года на M1 / 16 GB, macOS 27.0.1,
Instruments 27.0 (27A266a), release `-O`. В прежнем `MicrophoneRecorder.consume`
каждая порция записи создавала `AVAudioPCMBuffer` и копировала PCM, даже если
исходный pooled buffer целиком помещался в текущий CAF. Расчёт peak через
`map { abs($0) }.max()` создавал временный Float-массив.

Теперь файловая часть выделена в `MicrophoneCaptureWriter`. Целый входной
буфер записывается напрямую; на границах десятисекундного CAF и трёхчасового
лимита используется один scratch на 8192 Float32, выделенный до установки tap.
Peak вычисляется одним проходом без массива, с прежним поведением для пустого
входа и NaN. Recorder возвращает pooled buffer только после синхронного
`AVAudioFile.write(from:)` и завершения `consume` на последовательной writerQueue.
Сам входной буфер и его `frameLength` не меняются.

## Allocations

Отдельный [probe](../scripts/probe_capture_writer.swift) переиспользует один
входной буфер ёмкостью 8192 с `frameLength = 1024`: 20 000 порций моно Float32
48 kHz, 20 480 000 кадров, 42 полных CAF и короткий хвост. Peak вычисляется
каждые пять буферов, как при пороге meter в 100 ms. Микрофон, модели и
пользовательский архив не используются; временные CAF удаляются после прогона.
Baseline — выделенная из исходного recorder файловая логика с прежними
выделением/копированием каждого slice и `map` для peak; оптимизированный probe
компилируется из рабочего `MicrophoneCaptureWriter.swift`.

Из двух успешно завершённых trace экспортирована таблица Statistics:

| Категория, `count-total` | До | После |
| --- | ---: | ---: |
| `AVAudioPCMBuffer` | 20 033 | 2 |
| `_ContiguousArrayStorage<Float>` | 4 000 | 0 |
| Все heap allocations процесса | 140 501 | 36 346 |
| Суммарно выделенные heap bytes за прогон | 35 085 392 | 7 877 472 |

В «до» входят один входной буфер и 20 032 slice с учётом разрезаний; в «после» —
один входной буфер и один scratch. Настоящий callback по-прежнему использует
фиксированный пул из 32 буферов. Общие heap numbers включают запуск процесса
и AVFoundation и не означают пиковую память или RSS. Оба процесса завершились
с кодом 0 и вывели одинаковые `frames=20480000 peakSum=2000.0`.

Локальные артефакты в исключённой из Git `TestResults/capture-writer-allocations/`:
`baseline.swift`, executable/dSYM, `baseline-debug.trace`, `optimized.trace`,
`baseline-statistics.xml`, `optimized-statistics.xml`, stdout и `tests.log`.
Первый `baseline.trace` невалиден: Instruments не подключился к executable
без разрешения отладки. Успешные профили получены после ad-hoc подписи только
двух технических executable с `com.apple.security.get-task-allow`; подпись,
entitlements и sandbox LocalScribe не менялись.

Это проверка аллокаций writerQueue на синтетическом PCM. Она не доказывает
утечку, потерю аудио, ускорение записи или отсутствие пропусков на настоящем
микрофоне под нагрузкой. Время двух профилей не сравнивается: во время второго
также выполнялась сборка тестов.

## Проверки PCM и контейнеров

`MicrophoneCaptureWriterTests` сначала прошли на прежнем алгоритме, затем
на оптимизированном. Проверяются:

- побитовое равенство прочитанного из CAF PCM исходным Float32, включая
  знаковый ноль и subnormal, с разными данными по обе стороны стыков;
- повторное заполнение одного pooled buffer после каждой записи, неизменность
  его данных и `frameLength` во время записи;
- последовательные CAF ровно по десять секунд на 44,1 и 48 kHz, многократные
  разрезания, короткие буферы и хвост, пустая запись;
- публикация закрытого CAF на точной границе, удаление пустого `.partial.caf`
  при остановке, отсутствие `.partial.caf` после завершения;
- обрезание последнего буфера по трёхчасовому лимиту и игнорирование позднего
  входа; для этой проверки используется PCM 1 Hz и все 1080 границ CAF;
- совпадение peak с прежним расчётом, включая ноль, clipping, NaN и infinity.

Команды из корня пакета:

```sh
swift test -c release -j 4 --force-resolved-versions --filter MicrophoneCaptureWriterTests
swift test -c release -j 4 --force-resolved-versions
```

Полный release-прогон: 218 XCTest (120 Core, 67 UI/service, 31 диаризации),
0 ошибок, 2 ожидаемых модельных пропуска. Использованы имеющиеся Metal-артефакты;
чистая сборка Metal и настоящая трёхчасовая микрофонная запись не проверялись.

## Повторный профиль

После SwiftPM-сборки собрать probe с теми же объектами Core. Путь к продуктам
определяется через SwiftPM; поиск объектов ниже рассчитан на локальную
Xcode-сборку SwiftPM и требует ровно один комплект release-объектов Core.

```sh
python3 - <<'PY'
from pathlib import Path
import plistlib, subprocess

out = Path('TestResults/capture-writer-allocations').resolve()
out.mkdir(parents=True, exist_ok=True)
products = subprocess.check_output(
    ['swift', 'build', '-c', 'release', '--show-bin-path'], text=True).strip()
candidates = [p.parent for p in Path('.build').rglob('Contracts.o')
              if 'LocalScribeCore' in str(p.parent) and 'Release' in p.parts]
assert len(candidates) == 1, candidates
objects = sorted(candidates[0].glob('*.o'))
probe = out / 'optimized'
subprocess.run([
    'xcrun', 'swiftc', '-O', '-g', '-target', 'arm64-apple-macos26.0',
    '-module-cache-path', str(out / 'module-cache'), '-I', products,
    'Sources/LocalScribe/MicrophoneCaptureWriter.swift',
    'scripts/probe_capture_writer.swift', *map(str, objects), '-o', str(probe)
], check=True)
entitlements = out / 'probe-debug.plist'
entitlements.write_bytes(plistlib.dumps({'com.apple.security.get-task-allow': True}))
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements',
                str(entitlements), str(probe)], check=True)
PY
xcrun xctrace record --template Allocations \
  --output TestResults/capture-writer-allocations/repeat.trace \
  --target-stdout TestResults/capture-writer-allocations/repeat.stdout \
  --time-limit 20s --launch -- "$PWD/TestResults/capture-writer-allocations/optimized" 20000
xcrun xctrace export \
  --input TestResults/capture-writer-allocations/repeat.trace \
  --xpath '/trace-toc/run[@number="1"]/tracks/track[@name="Allocations"]/details/detail[@name="Statistics"]' \
  --output TestResults/capture-writer-allocations/repeat-statistics.xml
```

Для повторного запуска нужны новые имена trace/output. В ограниченной файловой
среде SwiftPM и Instruments требуют доступа к своим служебным кэшам.
