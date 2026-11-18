#!/usr/bin/env python3
"""Run an offline 2x2 ASR comparison; keep private artifacts only in TestResults.

SDK stdout/stderr are discarded. WER is computed only for explicitly reviewed
reference intervals, never against another automatic transcript.
"""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
import unicodedata
import wave

REPO = pathlib.Path(__file__).resolve().parents[1]
VARIANTS = {
    "A": ("first-pause-prefix-recovery", False),
    "B": ("first-pause-gap-recovery", True),
    "C": ("late-pause-prefix-recovery", False),
    "D": ("late-pause-v2-gap-recovery", True),
    "E": ("late-pause-context-review", False),
}
DEFAULT_VARIANTS = ["A", "B", "C", "D"]
REVIEW_RANGES = [
    ("opening", 0, 15000), ("figma", 158000, 179000),
    ("epics", 210000, 240000), ("allocation", 320000, 345000),
    ("coordination", 365000, 423000), ("payment", 450000, 499000),
    ("access", 567000, 626000),
]


def process_environment():
    # xctest can dump its environment on invocation errors. Do not give build or
    # inference children unrelated credentials or the agent's control variables.
    allowed = {"PATH", "HOME", "TMPDIR", "SDKROOT", "DEVELOPER_DIR", "LANG", "LC_ALL", "MallocNanoZone"}
    return {key: value for key, value in os.environ.items() if key in allowed}


def digest(path):
    result = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def read(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def write(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def tokens(text):
    # NFKC, casefold, ё→е; punctuation/hyphens separate words. No stemming,
    # translation, number expansion or automatic correction of technical terms.
    return re.findall(r"[^\W_]+", unicodedata.normalize("NFKC", text).casefold().replace("ё", "е"))


def word_errors(reference, hypothesis):
    """Levenshtein S/D/I with linear memory; ties prefer S, then D, then I."""
    previous = [(0, 0, i) for i in range(len(hypothesis) + 1)]
    for index, expected in enumerate(reference, 1):
        current = [(0, index, 0)]
        for column, actual in enumerate(hypothesis, 1):
            if expected == actual:
                current.append(previous[column - 1])
            else:
                sub, delete, insert = previous[column - 1], previous[column], current[-1]
                candidates = [(sub[0] + 1, sub[1], sub[2]),
                              (delete[0], delete[1] + 1, delete[2]),
                              (insert[0], insert[1], insert[2] + 1)]
                current.append(min(candidates, key=sum))
        previous = current
    sub, delete, insert = previous[-1]
    return {"referenceWords": len(reference), "substitutions": sub, "deletions": delete,
            "insertions": insert, "wer": (sub + delete + insert) / len(reference) if reference else None}


def interval_text(transcript, start, end):
    selected = []
    for segment in transcript["segments"]:
        units = segment.get("words") or [{"text": segment["text"], "startMs": segment["startMs"], "endMs": segment["endMs"]}]
        text = "".join(unit["text"] for unit in units if start <= (unit["startMs"] + unit["endMs"]) / 2 < end).strip()
        if text:
            selected.append(text)
    return " ".join(selected)


def reviewed_intervals(reference, source_hash, duration):
    if reference.get("schemaVersion") != 1 or reference.get("sourceHash") != source_hash:
        raise ValueError("Reference schema/source SHA does not match")
    result = sorted((s for s in reference["segments"] if s.get("verified") is True), key=lambda s: s["startMs"])
    previous_end = 0
    for item in result:
        if not (previous_end <= item["startMs"] < item["endMs"] <= duration):
            raise ValueError("Reviewed reference intervals overlap or exceed the audio")
        if not item.get("verifiedBy", "").strip():
            raise ValueError("Reviewed intervals need verifiedBy")
        kind = item.get("kind", "speech")
        if kind not in {"speech", "nonSpeech"}:
            raise ValueError("Reference kind must be speech or nonSpeech")
        if not isinstance(item.get("text"), str):
            raise ValueError("Reference text must be explicitly provided")
        if kind == "speech" and not tokens(item.get("text", "")):
            raise ValueError("Reviewed speech needs a nonempty text")
        if kind == "nonSpeech" and item.get("text", "").strip():
            raise ValueError("Reviewed nonSpeech must have an explicitly empty text")
        if not isinstance(item.get("wordBoundaryTruncated", False), bool):
            raise ValueError("wordBoundaryTruncated must be boolean")
        previous_end = item["endMs"]
    return result


def score_interval(interval, hypothesis, boundary_crossing_words=0):
    return {"id": interval["id"], "kind": interval.get("kind", "speech"),
            "excludedFromAggregateWER": interval.get("wordBoundaryTruncated", False),
            "nonSpeechBoundaryCrossingWords": boundary_crossing_words if interval.get("kind") == "nonSpeech" else 0,
            **word_errors(tokens(interval["text"]), tokens(hypothesis))}


def score_transcript_interval(interval, transcript):
    start, end = interval["startMs"], interval["endMs"]
    crossing = 0
    if interval.get("kind") == "nonSpeech":
        for segment in transcript["segments"]:
            for unit in segment.get("words") or [segment]:
                if start <= (unit["startMs"] + unit["endMs"]) / 2 < end and (unit["startMs"] < start or unit["endMs"] > end):
                    crossing += len(tokens(unit["text"]))
    return score_interval(interval, interval_text(transcript, start, end), crossing)


def owned_review_text(segments):
    # Review segments already own only the target's words. A changed segment has
    # deliberately lost word timings; its old segment midpoint must not drop it.
    return " ".join(segment["text"].strip() for segment in segments if segment["text"].strip())


def score_owned_review(interval, segments):
    score = score_transcript_interval(interval, {"segments": segments})
    score.update(word_errors(tokens(interval["text"]), tokens(owned_review_text(segments))))
    return score


def aggregate_scores(scores):
    included = [score for score in scores if not score["excludedFromAggregateWER"]]
    total = {key: sum(score[key] for score in included)
             for key in ["referenceWords", "substitutions", "deletions", "insertions"]}
    total["wer"] = sum(total[key] for key in ["substitutions", "deletions", "insertions"]) / total["referenceWords"] if total["referenceWords"] else None
    speech = [score for score in included if score["kind"] == "speech"]
    speech_words = sum(score["referenceWords"] for score in speech)
    total["speechWER"] = sum(score[key] for score in speech for key in ["substitutions", "deletions", "insertions"]) / speech_words if speech_words else None
    total["nonSpeechFalseWords"] = sum(score["insertions"] for score in included if score["kind"] == "nonSpeech")
    total["nonSpeechBoundaryCrossingWords"] = sum(score["nonSpeechBoundaryCrossingWords"] for score in included)
    total["excludedBoundaryIntervals"] = sum(score["excludedFromAggregateWER"] for score in scores)
    return total


def interval_audio(output, start, end, folder="review-audio"):
    # Time-based names avoid interpreting human reference IDs as file paths.
    clip_path = output / folder / f"{start}-{end}.wav"
    clip_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output / "input.wav"), "rb") as audio:
        if not (isinstance(start, int) and isinstance(end, int) and 0 <= start < end <= round(audio.getnframes() / 16)):
            raise ValueError("Review audio interval exceeds input")
        audio.setpos(start * 16)
        with wave.open(str(clip_path), "wb") as clip:
            clip.setparams(audio.getparams())
            clip.writeframes(audio.readframes(min(end * 16, audio.getnframes()) - start * 16))
    return clip_path


def timecode(milliseconds):
    seconds, ms = divmod(milliseconds, 1000)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02}:{minutes:02}:{seconds:02}.{ms:03}"


def make_review_inputs(output, source_hash, duration):
    clips = output / "review-audio"
    clips.mkdir()
    segments = []
    with wave.open(str(output / "input.wav"), "rb") as audio:
        for label, start, end in REVIEW_RANGES:
            end = min(end, duration)
            if start >= end:
                continue
            audio.setpos(start * 16)
            with wave.open(str(clips / f"{label}.wav"), "wb") as clip:
                clip.setparams(audio.getparams())
                clip.writeframes(audio.readframes((end - start) * 16))
            segments.append({"id": label, "startMs": start, "endMs": end,
                             "text": "", "verified": False, "verifiedBy": ""})
    write(output / "reference.template.json", {"schemaVersion": 1, "sourceHash": source_hash,
        "instructions": "Сверьте текст с аудио; укажите verified=true и verifiedBy только после прослушивания. Можно уточнять границы и добавлять непересекающиеся интервалы. Автоматические варианты не являются эталоном.",
        "segments": segments})


def report(output, reference_path=None):
    source = read(output / "input.json")
    with wave.open(str(output / "input.wav"), "rb") as audio:
        duration = round(audio.getnframes() / 16)
    if digest(output / "input.wav") != source["waveHash"]:
        raise ValueError("Prepared audio changed")
    reference_path = reference_path or output / "reference.template.json"
    reference = read(reference_path)
    intervals = reviewed_intervals(reference, source["sourceHash"], duration)
    rows = []
    reviews = ["# Проверка расшифровок по аудио", "",
               f"Подтверждено интервалов: {len(intervals)}. Оценки относятся только к ним; текст эталона сохраняет ручные формулировки." if intervals else
               "Эталон ещё не подтверждён. Заполните reference.template.json после прослушивания и повторите --report-only.", ""]
    transcripts = {}
    settings_hash = None
    for label, (policy, recovery) in VARIANTS.items():
        folder = output / label
        if not (folder / "measurement.json").exists():
            continue
        measurement, metrics = read(folder / "measurement.json"), read(folder / "metrics-asr.json")
        if (measurement["sourceHash"], measurement["waveHash"], measurement["codeHash"], measurement["profileHash"], measurement["windowPolicy"]) != (
                source["sourceHash"], source["waveHash"], source["codeHash"], source["run"]["profileHash"], policy):
            raise ValueError("Variant identity does not match this comparison")
        if metrics["status"] != "completed" or metrics["checkpointHits"] != 0 or metrics["plannedWindows"]["totalMs"] != duration:
            raise ValueError("Variant is incomplete or reused checkpoints")
        options_hash = digest(folder / "decoding-options.json")
        if settings_hash is not None and settings_hash != options_hash:
            raise ValueError("Decoding options differ between variants")
        settings_hash = options_hash
        transcript = read(folder / "transcript.json")
        transcripts[label] = transcript
        (folder / "transcript.txt").write_text("\n\n".join(
            f"[{timecode(s['startMs'])}–{timecode(s['endMs'])}] {s['text'].strip()}" for s in transcript["segments"]) + "\n", encoding="utf-8")
        groups = [metrics[k] for k in ["primary", "prefixRecovery", "gapRecovery", "contextReview"] if metrics.get(k) is not None]
        scores = [score_transcript_interval(interval, transcript) for interval in intervals]
        total = aggregate_scores(scores)
        rows.append({"variant": label, "windowPolicy": policy, "recoverInteriorGaps": recovery,
            "windows": metrics["plannedWindows"]["count"], "meanWindowMs": metrics["plannedWindows"]["meanMs"],
            "shortWindows": metrics["plannedWindows"]["histogram"][0],
            "calls": sum(g["inputs"]["count"] for g in groups), "modelWallSeconds": sum(g["wallSeconds"] for g in groups),
            "gapCalls": metrics["gapRecovery"]["inputs"]["count"],
            "contextReviewCalls": (metrics.get("contextReview") or {}).get("inputs", {}).get("count", 0),
            "unrecoveredPrefixes": metrics["unrecoveredPrefixes"], "unrecoveredGaps": metrics["unrecoveredGaps"],
            "unintelligibleSegments": sum("[неразборчиво]" in s["text"] for s in transcript["segments"]),
            "thermalStateBefore": measurement["thermalStateBefore"], "thermalStateAfter": measurement["thermalStateAfter"],
            "reviewedScore": total, "intervalScores": scores})
    for segment in reference["segments"]:
        clip = interval_audio(output, segment["startMs"], segment["endMs"])
        # Human-edited reference fields are untrusted Markdown: collapse line
        # breaks so they cannot escape the heading/paragraph and add blocks.
        identifier = " ".join(str(segment["id"]).split())
        reviews += [f"## {identifier} · {timecode(segment['startMs'])}–{timecode(segment['endMs'])}", "",
                    f"![Аудио]({clip})", ""]
        if segment.get("verified") is True:
            reviews += ["**Проверенный текст:** " + (" ".join(segment["text"].split()) or "[нет речи]"), ""]
            if segment.get("wordBoundaryTruncated"):
                reviews += ["Слово обрезано границей фрагмента; интервал исключён из суммарного WER.", ""]
        for label, transcript in transcripts.items():
            reviews += [f"**{label}**", "", interval_text(transcript, segment["startMs"], segment["endMs"]) or "[нет текста]", ""]
    write(output / "comparison.json", {"schemaVersion": 1, "sourceHash": source["sourceHash"],
        "referenceSHA256": digest(reference_path), "scorerSHA256": digest(__file__),
        "qualityStatus": "partial-reviewed-reference" if intervals else "awaiting-reviewed-reference",
        "reviewedIntervals": len(intervals), "reviewedDurationMs": sum(s["endMs"] - s["startMs"] for s in intervals), "variants": rows})
    lines = ["# Сравнение ASR 2×2", "", "Все варианты: offline, части 300 с, один последовательный процесс, одинаковые настройки Whisper, без ASR checkpoints.", "",
             "WER доступен только для вручную подтверждённых интервалов. Скорость, длина текста и предупреждения сами по себе не определяют качество.", "",
             "| Вариант | Окна | Среднее, с | Вызовы | Повторы пропусков | Время модели, с | WER речи | Ложные слова без речи |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in rows:
        score = row["reviewedScore"]["speechWER"]
        wer = "ожидает эталона" if score is None else f"{score:.1%}"
        lines.append(f"| {row['variant']} | {row['windows']} | {row['meanWindowMs']/1000:.2f} | {row['calls']} | {row['gapCalls']} | {row['modelWallSeconds']:.1f} | {wer} | {row['reviewedScore']['nonSpeechFalseWords']} |")
    lines += ["", "A/B — первая пауза, C/D/E — поздняя; B/D восстанавливают внутренние пропуски и хвост. E сохраняет альтернативы с изменённым контекстом отдельно, без замены основного текста. Восстановление начала включено у всех.", "",
              "Температурные повторы допускают недетерминированность. Порядок A→B→C→D и состояние охлаждения могут влиять на время; близкие результаты требуют повторения.", "",
              f"Подтверждено интервалов: {len(intervals)}. Даже заполненный шаблон покрывает только выбранные участки, а не всю запись.", "",
              "Явно подтверждённые nonSpeech-интервалы учитываются как ложные слова по их текущим таймкодам; их WER при нуле эталонных слов не определён. Слова, пересекающие границы nonSpeech, отмечены отдельно в JSON: это может быть ошибкой выравнивания соседней речи. Оборванное границей слово исключает интервал из суммарного WER; дословная оценка интервала остаётся в JSON. Суммарный JSON wer включает вставки на nonSpeech, speechWER относится только к речи.", ""]
    if source.get("baselineReuse"):
        lines[2:2] = ["A/C повторно использованы побайтно из замороженной матрицы; их время историческое. Новые вызовы только в E/metrics-asr.json. Это reuse baseline, не production checkpoints. Сравнение четырёх гипотез на общей разметке — control-comparison.json.", ""]
    (output / "comparison.md").write_text("\n".join(lines), encoding="utf-8")
    (output / "review.md").write_text("\n".join(reviews), encoding="utf-8")
    context_reviews = ["# Альтернативы с изменённым контекстом", "",
        "Кандидаты не применены к расшифровке и не считаются эталоном. Сверяйте оба текста с аудио.", ""]
    context_scores = []
    reviewed_by_range = {(interval["startMs"], interval["endMs"]): interval for interval in intervals}
    for path in sorted((output / "E" / "context-reviews").glob("window-*.json")):
        batch = read(path)
        context_reviews += [f"Окно {timecode(batch['coreStartMs'])}: отложено целей {batch['deferredTargets']}, одинаковых входов пропущено {batch['unchangedContextTargets']}.", ""]
        for review in batch["reviews"]:
            request = review["request"]
            clip_path = interval_audio(output, request["startMs"], request["endMs"], "E/context-review-audio")
            context_reviews += [f"## {timecode(request['startMs'])}–{timecode(request['endMs'])}", "",
                f"Причины: {', '.join(request['reasons'])}. Контекст: {timecode(request['contextStartMs'])}–{timecode(request['contextEndMs'])}.", "",
                f"![Аудио]({clip_path})", "",
                "**Исходный вариант:** " + interval_text({"segments": review["original"]}, request["startMs"], request["endMs"]), "",
                "**Кандидат:** " + (interval_text({"segments": review["candidate"]}, request["startMs"], request["endMs"]) or "[нет текста]"), ""]
            repair = review.get("wordRepair")
            if repair is not None:
                context_reviews += ["**Точечная правка (предложение):** " + (owned_review_text(repair["proposed"]) or "[нет текста]"), "",
                    f"Алгоритм: {repair['algorithmVersion']}. Замен слов: {len(repair['edits'])}. Признаки: {', '.join(repair['issues']) or 'нет'}.", ""]
                for edit in repair["edits"]:
                    context_reviews += [f"- {edit['original']['text'].strip()} → {edit['replacementText'].strip()}"]
                if repair["edits"]:
                    context_reviews += ["", "Word timings изменённых сегментов удалены; сохранены исходные границы сегментов и неопределённость.", ""]
            interval = reviewed_by_range.get((request["startMs"], request["endMs"]))
            if interval:
                context_reviews += ["**Проверенный текст:** " + (interval["text"] or "[нет речи]"), ""]
                if interval.get("wordBoundaryTruncated"):
                    context_reviews += ["Обрезанное слово: интервал исключён из суммарного WER.", ""]
                hypotheses = {label: review[label] for label in ["original", "candidate"]}
                if repair is not None:
                    hypotheses["proposed"] = repair["proposed"]
                context_scores.append({"id": interval["id"], "startMs": interval["startMs"], "endMs": interval["endMs"],
                    **{label: score_owned_review(interval, segments) if label == "proposed" else score_transcript_interval(interval, {"segments": segments})
                       for label, segments in hypotheses.items()}})
    if (output / "E" / "context-reviews").exists():
        labels = ["original", "candidate"] + (["proposed"] if any("proposed" in item for item in context_scores) else [])
        totals = {label: aggregate_scores([item[label] for item in context_scores if label in item]) for label in labels}
        write(output / "context-scores.json", {"schemaVersion": 1, "sourceHash": source["sourceHash"],
            "referenceSHA256": digest(reference_path), "scorerSHA256": digest(__file__),
            "scope": "exact-reviewed-context-intervals-only", "intervals": context_scores, "totals": totals,
            "evaluatedIntervals": {label: sum(label in item for item in context_scores) for label in labels}})
        if context_scores:
            summary = ["Оценки относятся только к подтверждённым целям повтора. Предложения не применены к основному результату.", "",
                "| Гипотеза | Эталонных слов | WER речи | Пропуски | Слова на nonSpeech по таймкодам |",
                "| --- | ---: | ---: | ---: | ---: |"]
            names = {"original": "Исходная", "candidate": "Весь повтор", "proposed": "Точечная правка"}
            for label, total in totals.items():
                wer = "нет эталонных слов" if total["speechWER"] is None else f"{total['speechWER']:.1%}"
                summary.append(f"| {names[label]} | {total['referenceWords']} | {wer} | {total['deletions']} | {total['nonSpeechFalseWords']} |")
            context_reviews[4:4] = summary + [""]
        (output / "context-review.md").write_text("\n".join(context_reviews), encoding="utf-8")


def test_bundle(explicit=None):
    clean = process_environment()
    if explicit is None:
        subprocess.run(["swift", "test", "-c", "release", "-j", "4", "--force-resolved-versions", "--filter", "ASRMatrixProbeTests"], cwd=REPO, env=clean, check=True)
        binary_dir = pathlib.Path(subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=REPO, env=clean, text=True).strip())
        explicit = binary_dir / "LocalScribeDiarizationTests.xctest"
    bundle = explicit.resolve()
    if not bundle.is_dir():
        raise ValueError("Supply the built LocalScribeDiarizationTests.xctest with --test-bundle")
    return bundle


def repair_replay(args, output):
    source = args.repair_replay.resolve()
    output = output.resolve()
    if output.exists() or source == output or output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError("Replay needs a separate fresh output directory")
    source_input = read(source / "input.json")
    if digest(source / "input.wav") != source_input["waveHash"]:
        raise ValueError("Replay source audio changed")
    required = ["input.json", "input.wav", "E/measurement.json", "E/metrics-asr.json", "E/transcript.json", "E/decoding-options.json"]
    required += [str(path.relative_to(source)) for path in sorted((source / "E/context-reviews").glob("window-*.json"))]
    original_hashes = {name: digest(source / name) for name in required}
    reference = args.reference or (source / "reference.reviewed.json" if (source / "reference.reviewed.json").exists() else source / "reference.template.json")
    reference_hash = digest(reference)
    output.mkdir(parents=True, mode=0o700)
    shutil.copy2(source / "input.json", output / "input.json")
    shutil.copy2(source / "input.wav", output / "input.wav")
    shutil.copytree(source / "E", output / "E")
    hashes = {name: digest(REPO / name) for name in [
        "Sources/LocalScribeWorker/ASRWordRepair.swift", "Sources/LocalScribeWorker/ASRContextReview.swift",
        "Sources/LocalScribeWorker/SpeechRecognizer.swift",
        "Sources/LocalScribeWorker/WhisperASREngine.swift", "Sources/LocalScribeWorker/WhisperASRWindowing.swift",
        "Sources/LocalScribeWorker/WhisperASRMetrics.swift", "Sources/LocalScribeWorker/ASREngine.swift",
        "Sources/LocalScribeCore/ASR.swift", "Tests/LocalScribeDiarizationTests/WhisperTestSupport.swift", "Tests/LocalScribeDiarizationTests/ASRMatrixProbeTests.swift",
        "Tests/LocalScribeDiarizationTests/ASRWordRepairTests.swift", "scripts/probe_asr_matrix.py", "Package.swift", "Package.resolved"]}
    for name in sorted((REPO / "Sources/LocalScribeCore").glob("*.swift")):
        hashes[str(name.relative_to(REPO))] = digest(name)
    bundle = test_bundle(args.test_bundle)
    env = process_environment()
    env.update(LOCALSCRIBE_ASR_WORD_REPAIR_REPLAY="technical-probe", LOCALSCRIBE_ASR_MATRIX_OUTPUT=str(output))
    child = subprocess.Popen(["xcrun", "xctest", "-XCTest", "LocalScribeDiarizationTests.ASRMatrixProbeTests/testExplicitWordRepairReplay", str(bundle)],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        child.wait(timeout=min(args.timeout, 300))
    finally:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if child.poll() is None:
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
    if child.returncode != 0 or not (output / "word-repair-info.json").exists():
        raise RuntimeError("Word repair replay failed; SDK/test output was discarded")
    if any(digest(source / name) != expected for name, expected in original_hashes.items()) or digest(reference) != reference_hash:
        raise ValueError("Frozen source hypotheses or reference changed")
    if any(digest(REPO / name) != expected for name, expected in hashes.items()):
        raise ValueError("Repair algorithm changed during replay")
    # The Swift repair never reads the reference. Copy it only after replay.
    shutil.copy2(reference, output / "reference.reviewed.json")
    if (source / "reference.template.json").exists():
        shutil.copy2(source / "reference.template.json", output / "reference.template.json")
    report(output, output / "reference.reviewed.json")
    write(output / "replay-environment.json", {"sourceDirectory": str(source), "sourceHash": source_input["sourceHash"],
        "inputHashes": original_hashes, "referenceSHA256": reference_hash, "algorithmSourceHashes": hashes,
        "testBinarySHA256": digest(bundle / "Contents/MacOS/LocalScribeDiarizationTests"), "newModelCalls": 0})
    for name, expected in hashes.items():
        snapshot = output / "source-snapshot" / name
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / name, snapshot)
        if digest(snapshot) != expected:
            raise ValueError("Repair snapshot changed")
    print("Word repair replay completed; source hypotheses unchanged; new model calls: 0", flush=True)


CONTROL_RANGES = [("figma", 158000, 179000), ("technical-ru-en", 365000, 423000), ("access", 567000, 626000)]


def run_frozen_phase(bundle, output, phase, timeout):
    env = process_environment()
    env.update(LOCALSCRIBE_ASR_FROZEN_PROBE="technical-probe", LOCALSCRIBE_ASR_MATRIX_OUTPUT=str(output),
               LOCALSCRIBE_ASR_FROZEN_PHASE=phase)
    child = subprocess.Popen(["xcrun", "xctest", "-XCTest",
        "LocalScribeDiarizationTests.ASRFrozenBaselineProbeTests/testExplicitFrozenBaselineContext", str(bundle)],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    started = last_update = time.monotonic()
    try:
        while child.poll() is None:
            now = time.monotonic()
            if now - started > timeout:
                raise TimeoutError("Frozen baseline probe timed out")
            if now - last_update >= 30:
                path = output / "E/metrics-asr.json"
                metrics = read(path) if path.exists() else {}
                print(json.dumps({"phase": phase, "elapsedSeconds": round(now - started),
                    "contextCalls": (metrics.get("contextReview") or {}).get("inputs", {}).get("count", 0)}), flush=True)
                last_update = now
            time.sleep(0.5)
    finally:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if child.poll() is None:
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
    marker = output / ("frozen-plan.json" if phase == "plan" else "E/selective-info.json")
    if child.returncode != 0 or not marker.exists():
        raise RuntimeError("Frozen baseline probe failed; inspect frozen-state.json; SDK/test output discarded")


def frozen_reference(output, source_hash):
    # All targets retain their true boundaries. Expand evaluation coverage at the
    # edges when necessary and partition it; never slice a timing-free proposal.
    plan = read(output / "frozen-plan.json")
    requests = [r for w in plan["windows"] for r in w["requests"]]
    segments = []
    clips = []
    for label, start, end in CONTROL_RANGES:
        clip = interval_audio(output, start, end)
        clips.append({"id": label, "startMs": start, "endMs": end, "path": str(clip), "sha256": digest(clip)})
        selected = sorted([r for r in requests if r["startMs"] < end and start < r["endMs"]], key=lambda r: r["startMs"])
        left = min([start] + [r["startMs"] for r in selected])
        right = max([end] + [r["endMs"] for r in selected])
        cursor = left
        units = []
        for r in selected:
            if r["startMs"] < cursor:
                raise ValueError("Frozen context targets overlap; cannot form an unbiased partition")
            if cursor < r["startMs"]:
                units.append((cursor, r["startMs"], False))
            units.append((r["startMs"], r["endMs"], True))
            cursor = r["endMs"]
        if cursor < right:
            units.append((cursor, right, False))
        for index, (a, b, target) in enumerate(units, 1):
            clip = interval_audio(output, a, b, "annotation-audio")
            context_clip = interval_audio(output, max(0, a - 2000), min(plan["durationMs"], b + 2000), "listening-context")
            segments.append({"id": f"{label}-{index:02}", "startMs": a, "endMs": b, "text": "", "kind": "speech",
                "verified": False, "verifiedBy": "", "wordBoundaryTruncated": False, "contextTarget": target,
                "audioPath": str(clip), "listeningContextPath": str(context_clip)})
    write(output / "reference.template.json", {"schemaVersion": 1, "sourceHash": source_hash,
        "instructions": "Сначала слушайте аудио без автоматических гипотез. Запишите дословно, сохраняя RU/EN, повторы, отрицания и числа. Таймкоды — в полной встрече. Заполните verifiedBy и verified=true только после проверки. Шум: kind=nonSpeech, text=пустая строка. Можно делить интервалы; для предложения со снятыми word timings оценивается только целая исходная contextTarget. На обрезанном слове уточните границу или отметьте wordBoundaryTruncated=true. Не переносите слова из соседнего listening-context в целевой интервал.",
        "segments": segments})
    write(output / "listening-clips.json", clips)
    lines = ["# Аудио для независимой ручной разметки", "", "Автоматические гипотезы находятся отдельно. Эталон пока пустой.", "",
        "Сначала прослушайте три основных фрагмента и запишите дословно всё слышимое, включая английские реплики и повторы. Шум и неуверенно услышанные места отметьте отдельно. Таймкоды ниже относятся к полной встрече.", ""]
    for clip in clips:
        lines += [f"## {clip['id']}: {timecode(clip['startMs'])}–{timecode(clip['endMs'])}", "", f"![Аудио]({clip['path']})", ""]
    lines += ["## Точные интервалы шаблона", "", "Некоторые цели выходят за край основного фрагмента: для оценки повтора нужен весь такой интервал. Соседний контекст помогает услышать границу; расшифровывайте только целевой интервал.", ""]
    for segment in segments:
        lines += [f"- {segment['id']}: {timecode(segment['startMs'])}–{timecode(segment['endMs'])}; "
            f"[целевое аудио]({segment['audioPath']}), [с контекстом ±2 с]({segment['listeningContextPath']})."]
    (output / "LISTEN-FIRST.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def frozen_comparison(output, reference_path=None):
    source = read(output / "input.json")
    reference_path = reference_path or output / "reference.template.json"
    reference = read(reference_path)
    duration = read(output / "frozen-plan.json")["durationMs"]
    intervals = reviewed_intervals(reference, source["sourceHash"], duration)
    transcripts = {label: read(output / label / "transcript.json") for label in ("A", "C")}
    reviews = {}
    for path in (output / "E/context-reviews").glob("*.json"):
        for review in read(path)["reviews"]:
            r = review["request"]
            reviews[(r["startMs"], r["endMs"])] = review
    units = []
    scores = {label: [] for label in ("A", "C", "repeat", "proposed")}
    for unit in reference["segments"]:
        a, b = unit["startMs"], unit["endMs"]
        review = reviews.get((a, b))
        # A baseline unit with no request stays C in both treatment variants.
        # Refuse partial intersections: timing-free proposals cannot be sliced.
        partial = any(x < b and a < y for x, y in reviews) and review is None
        texts = {label: interval_text(t, a, b) for label, t in transcripts.items()}
        texts.update(repeat=owned_review_text(review["candidate"]) if review else texts["C"],
                     proposed=owned_review_text(review["wordRepair"]["proposed"]) if review else texts["C"])
        entry = {"id": unit["id"], "startMs": a, "endMs": b, "contextTarget": review is not None,
                 "partialTargetUnsupported": partial, "texts": texts}
        if unit in intervals and not partial:
            for label in scores:
                if review and label in ("repeat", "proposed"):
                    segments = review["candidate"] if label == "repeat" else review["wordRepair"]["proposed"]
                    score = score_owned_review(unit, segments)
                else:
                    score = score_transcript_interval(unit, transcripts[label if label in transcripts else "C"])
                scores[label].append(score)
        units.append(entry)
    result = {"schemaVersion": 1, "scope": "partitioned-control-intervals-only", "sourceHash": source["sourceHash"],
        "referenceSHA256": digest(reference_path), "scorerSHA256": digest(__file__),
        "qualityStatus": "partial-reviewed-reference" if any(scores.values()) else "awaiting-reviewed-reference",
        "contextStatus": "completed" if (output / "E/selective-info.json").exists() else "not-confirmed-complete",
        "units": units, "scores": {label: aggregate_scores(value) for label, value in scores.items()},
        "evaluatedIntervals": {label: len(value) for label, value in scores.items()}}
    write(output / "control-comparison.json", result)
    lines = ["# Сравниваемые варианты — читать после ручной расшифровки", "",
        "A и C — фиксированные гипотезы исходной полной матрицы. Repeat и proposed — только локальные альтернативы C в точных целях, в остальных интервалах они равны C. Предложения не склеиваются в новый Transcript и не применяются к pipeline.", "",
        "WER ожидает ручного эталона." if not intervals else "Оценки относятся только к подтверждённым непересекающимся единицам.", ""]
    for unit in units:
        lines += [f"## {unit['id']}: {timecode(unit['startMs'])}–{timecode(unit['endMs'])}", ""]
        for label, text in unit["texts"].items():
            lines += [f"**{label}:** {text or '[нет текста]'}", ""]
    (output / "control-comparison.md").write_text("\n".join(lines), encoding="utf-8")


def context_from_baseline(args, output):
    source = args.context_from_baseline.resolve()
    if output.exists() or source == output or output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError("Frozen baseline needs a separate fresh output directory")
    if not source.is_relative_to(REPO / "TestResults") or not args.recording:
        raise ValueError("Supply a local TestResults baseline and --recording for original SHA validation")
    baseline = read(source / "input.json")
    recording = args.recording.resolve()
    manifest = read(recording / "manifest.json")
    original = (recording / manifest["originalRelativePath"]).resolve()
    if not original.is_relative_to(recording) or not manifest.get("sourceComplete") or digest(original) != baseline["sourceHash"]:
        raise ValueError("Original completeness/SHA does not match C")
    if read(recording / "runs" / baseline["run"]["id"] / "run.json") != baseline["run"]:
        raise ValueError("Pinned archive run changed")
    required = ["input.json", "input.wav", "environment.json"]
    for label in ("A", "C"):
        required += [f"{label}/{name}" for name in ("measurement.json", "metrics-asr.json", "transcript.json", "decoding-options.json")]
        required += [str(p.relative_to(source)) for p in sorted((source / label / "parts").glob("*.json"))]
        measurement = read(source / label / "measurement.json")
        if any(measurement[key] != baseline[key] for key in ("sourceHash", "waveHash", "codeHash")) or not measurement["networkDenied"]:
            raise ValueError("Frozen variant identity changed")
    if digest(source / "input.wav") != baseline["waveHash"]:
        raise ValueError("Frozen PCM changed")
    old_hashes = read(source / "environment.json")["sourceHashes"]
    planner = "Sources/LocalScribeCore/Analysis.swift"
    if digest(REPO / planner) != old_hashes[planner]:
        raise ValueError("C window planner changed; fresh full-source comparison required")
    # Freeze the already evaluated v1, not new tuning on these controls.
    repair_environment = args.repair_environment or (REPO / "TestResults/asr-word-repair-payment-20261020-final/replay-environment.json")
    if not repair_environment.is_file():
        raise ValueError("Pass --repair-environment with the replay-environment.json from the validated word-repair run")
    frozen = read(repair_environment)["algorithmSourceHashes"]
    for name in ("Sources/LocalScribeWorker/ASRWordRepair.swift", "Sources/LocalScribeWorker/ASRContextReview.swift"):
        if digest(REPO / name) != frozen[name]:
            raise ValueError("Prototype v1 changed before first control evaluation")
    input_hashes = {name: digest(source / name) for name in required}
    names = sorted(set(old_hashes) | {"Sources/LocalScribeWorker/ASRWordRepair.swift", "Sources/LocalScribeWorker/ASRContextReview.swift",
        "Tests/LocalScribeDiarizationTests/ASRFrozenBaselineProbeTests.swift", "scripts/tests/test_probe_asr_matrix.py"})
    hashes = {name: digest(REPO / name) for name in names}
    output.mkdir(parents=True, mode=0o700)
    for label in ("A", "C"):
        shutil.copytree(source / label, output / label)
    shutil.copy2(source / "input.wav", output / "input.wav")
    write(output / "baseline-input.json", baseline)
    new_input = dict(baseline, wavePath=str(output / "input.wav"),
        probeCodeHash=hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
        baselineReuse=True, baselineDirectory=str(source))
    # codeHash intentionally identifies A/C's historical inference, not new calls.
    write(output / "input.json", new_input)
    write(output / "control-intervals.json", [{"id": label, "startMs": a, "endMs": b} for label, a, b in CONTROL_RANGES])
    bundle = test_bundle(args.test_bundle)
    environment = {"mode": "selective-context-from-frozen-C", "baselineDirectory": str(source), "baselineInputHashes": input_hashes,
        "sourceHashes": hashes, "testBinarySHA256": digest(bundle / "Contents/MacOS/LocalScribeDiarizationTests"),
        "gitHEAD": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "platform": platform.platform(), "baselineTimingIsHistorical": True}
    write(output / "environment.json", environment)
    for name, expected in hashes.items():
        path = output / "source-snapshot" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / name, path)
        if digest(path) != expected:
            raise ValueError("Probe snapshot changed")
    try:
        run_frozen_phase(bundle, output, "plan", min(args.timeout, 300))
        frozen_reference(output, baseline["sourceHash"])
        print("Frozen plan validated; full PCM and blank reference prepared", flush=True)
        if not args.prepare_only:
            run_frozen_phase(bundle, output, "recognize", args.timeout)
        report(output, args.reference)
        frozen_comparison(output, args.reference)
        if any(digest(source / name) != expected or (output / name).exists() and digest(output / name) != expected
               for name, expected in input_hashes.items() if name not in {"input.json", "environment.json"}):
            raise ValueError("Frozen baseline artifacts changed")
        if any(digest(source / name) != expected for name, expected in input_hashes.items()):
            raise ValueError("Original baseline changed")
        if any(digest(REPO / name) != expected for name, expected in hashes.items()):
            raise ValueError("Probe source changed during inference")
        if digest(original) != baseline["sourceHash"] or digest(output / "input.wav") != baseline["waveHash"]:
            raise ValueError("Source audio changed during selective context inference")
    finally:
        write(output / "integrity.json", {"sourceHashBefore": baseline["sourceHash"], "sourceHashAfter": digest(original),
            "waveHashAfter": digest(output / "input.wav"),
            "baselineUnchanged": all(digest(source / name) == expected for name, expected in input_hashes.items())})
    print("Frozen C selective context preparation completed", flush=True)


def run_variant(bundle, label, output, timeout):
    env = process_environment()
    env.update(LOCALSCRIBE_ASR_MATRIX_PROBE="technical-probe", LOCALSCRIBE_ASR_MATRIX_INPUT=str(output / "input.json"),
               LOCALSCRIBE_ASR_MATRIX_OUTPUT=str(output / label), LOCALSCRIBE_ASR_MATRIX_VARIANT=label)
    command = ["xcrun", "xctest", "-XCTest", "LocalScribeDiarizationTests.ASRMatrixProbeTests/testExplicitOfflineMatrixVariant", str(bundle)]
    # Network denial is installed and checked by CWorkerIsolation inside the test,
    # before loading models. No private SDK text is retained in any log.
    child = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    started = last_update = time.monotonic()
    try:
        while child.poll() is None:
            now = time.monotonic()
            if now - started > timeout:
                raise TimeoutError(f"Variant {label} timed out")
            if now - last_update >= 30:
                metrics_path = output / label / "metrics-asr.json"
                metrics = read(metrics_path) if metrics_path.exists() else {}
                print(json.dumps({"variant": label, "elapsedSeconds": round(now - started),
                    "plannedAudioMs": metrics.get("plannedWindows", {}).get("totalMs", 0),
                    "calls": sum((metrics.get(k) or {}).get("inputs", {}).get("count", 0) for k in ["primary", "prefixRecovery", "gapRecovery", "contextReview"])}), flush=True)
                last_update = now
            time.sleep(0.5)
    finally:
        # Also clean up SDK descendants if the leader has already exited.
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if child.poll() is None:
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
    if child.returncode != 0 or not (output / label / "measurement.json").exists():
        raise RuntimeError(f"Variant {label} failed; inspect numeric metrics (SDK output was discarded)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recording", type=pathlib.Path)
    parser.add_argument("--reference-run", help="Frozen run ID; defaults to activeRunId")
    parser.add_argument("--models", type=pathlib.Path)
    parser.add_argument("--catalog", type=pathlib.Path, default=REPO / "Resources/models.lock.json")
    parser.add_argument("--tools", type=pathlib.Path)
    parser.add_argument("--test-bundle", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--reference", type=pathlib.Path)
    parser.add_argument("--report-only", action="store_true")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--context-from-baseline", type=pathlib.Path, help="Reuse full frozen A/C and decode selected C contexts only")
    parser.add_argument("--repair-environment", type=pathlib.Path, help="Word-repair replay-environment.json used by --context-from-baseline")
    parser.add_argument("--repair-replay", type=pathlib.Path, help="Propose word repairs on a copied completed E run; no new inference")
    parser.add_argument("--timeout", type=int, default=14400, help="Seconds per variant")
    parser.add_argument("--variants", nargs="+", choices=VARIANTS, default=DEFAULT_VARIANTS,
                        help="Variants to run; E saves context alternatives without applying them")
    args = parser.parse_args()
    if len(set(args.variants)) != len(args.variants):
        parser.error("--variants must not contain duplicates")
    output = args.output.resolve()
    if not output.is_relative_to(REPO / "TestResults"):
        parser.error("--output must be a dedicated directory under this repository's TestResults")
    if args.report_only:
        report(output, args.reference)
        if (output / "frozen-plan.json").exists():
            frozen_comparison(output, args.reference)
        return
    if args.context_from_baseline:
        context_from_baseline(args, output)
        return
    if args.repair_replay:
        repair_replay(args, output)
        return
    if not all([args.recording, args.models, args.tools]):
        parser.error("--recording, --models and --tools are required")
    if output.exists():
        parser.error("--output must not exist; each matrix uses fresh results")
    recording, models, tools = args.recording.resolve(), args.models.resolve(), args.tools.resolve()
    manifest = read(recording / "manifest.json")
    run_id = args.reference_run or manifest["activeRunId"]
    if pathlib.Path(run_id).name != run_id:
        parser.error("Invalid run ID")
    run = read(recording / "runs" / run_id / "run.json")
    if manifest.get("channels") != 1:
        raise ValueError("This probe expects mono input; stereo preparation needs the production phase-cancellation check")
    original = (recording / manifest["originalRelativePath"]).resolve()
    if not original.is_relative_to(recording) or not manifest.get("sourceComplete") or digest(original) != manifest["sha256"] or run["sourceHash"] != manifest["sha256"]:
        raise ValueError("Original SHA/completeness does not match the frozen run")
    output.mkdir(parents=True, mode=0o700)
    hashes = {str(p.relative_to(REPO)): digest(p) for p in sorted((REPO / "Sources/LocalScribeCore").glob("*.swift"))}
    for name in ["Sources/LocalScribeWorker/SpeechRecognizer.swift",
        "Sources/LocalScribeWorker/WhisperASREngine.swift", "Sources/LocalScribeWorker/WhisperASRWindowing.swift",
        "Sources/LocalScribeWorker/WhisperASRMetrics.swift", "Sources/LocalScribeWorker/ASREngine.swift",
        "Sources/LocalScribeCore/ASR.swift", "Tests/LocalScribeDiarizationTests/WhisperTestSupport.swift", "Sources/LocalScribeWorker/ASRMetrics.swift",
                 "Sources/LocalScribeWorker/ASRContextReview.swift",
                 "Sources/LocalScribeWorker/ASRWordRepair.swift",
                 "Tests/LocalScribeDiarizationTests/ASRMatrixProbeTests.swift", "Package.swift", "Package.resolved", "scripts/probe_asr_matrix.py"]:
        hashes[name] = digest(REPO / name)
    code_hash = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    subprocess.run([str(tools / "ffmpeg"), "-nostdin", "-n", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", str(original),
        "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(output / "input.wav")],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with wave.open(str(output / "input.wav"), "rb") as audio:
        duration = round(audio.getnframes() / 16)
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000) or abs(duration - manifest["durationMs"]) > 150:
            raise ValueError("Prepared audio format/duration does not match")
    write(output / "input.json", {"schemaVersion": 1, "sourceType": "technical-probe", "sourceHash": manifest["sha256"],
        "waveHash": digest(output / "input.wav"), "codeHash": code_hash, "wavePath": str(output / "input.wav"),
        "modelsPath": str(models), "run": run, "catalog": read(args.catalog)})
    write(output / "environment.json", {"platform": platform.platform(), "sourceHashes": hashes,
        "gitHEAD": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "variantOrder": args.variants, "sourceHash": manifest["sha256"], "durationMs": duration,
        "ffmpegSHA256": digest(tools / "ffmpeg")})
    make_review_inputs(output, manifest["sha256"], duration)
    report(output, args.reference)
    if args.prepare_only:
        return
    bundle = test_bundle(args.test_bundle)
    environment = read(output / "environment.json")
    environment["testBinarySHA256"] = digest(bundle / "Contents/MacOS/LocalScribeDiarizationTests")
    write(output / "environment.json", environment)
    try:
        for label in args.variants:
            print(f"Starting variant {label}", flush=True)
            run_variant(bundle, label, output, args.timeout)
            if digest(original) != manifest["sha256"]:
                raise ValueError("Archive original changed")
            if any(digest(REPO / name) != expected for name, expected in hashes.items()):
                raise ValueError("ASR source snapshot changed during comparison")
            report(output, args.reference)
            print(f"Completed variant {label}", flush=True)
    finally:
        write(output / "integrity.json", {"sourceHashBefore": manifest["sha256"], "sourceHashAfter": digest(original),
            "waveHashAfter": digest(output / "input.wav")})


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as error:
        # Errors refer to harness state only; subprocess SDK streams are never read.
        print(f"ASR comparison failed: {error}", file=sys.stderr)
        sys.exit(1)
