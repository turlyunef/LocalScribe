#!/usr/bin/env python3
"""Read-only Apple Speech / primary ASR experiment. Private output stays in TestResults.

Replay is continuous, starts at zero, and rejects dropped input. It does not test
microphone load, restarts, language changes, or the existing untimed captions file.
References are used only AFTER candidate selection; no changes enter the archive.
"""
import argparse
import difflib
import math
import pathlib
import platform
import re
import shutil
import signal
import subprocess
import time
import wave

from probe_asr_matrix import REPO, digest, process_environment, read, tokens, word_errors, write

VERSION = "caption-comparison-v1"
MAX_DIFFERENCE_WORDS = 5
ANCHOR_WORDS = 2
TIME_TOLERANCE_MS = 1000
MAX_SOURCE_MS = 180_000


def validate_input(spec):
    sources = spec.get("sources", [])
    if spec.get("schemaVersion") != 1 or not 1 <= len(sources) <= 20:
        raise ValueError("Expected schemaVersion 1 and 1–20 sources")
    if len({s["id"] for s in sources}) != len(sources):
        raise ValueError("Duplicate source IDs")
    for source in sources:
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", source["id"]):
            raise ValueError("Unsafe source ID")
        if source["language"] not in ("russian", "english", "mixed"):
            raise ValueError("Unsupported language")
        if not 0 < source["durationMs"] <= MAX_SOURCE_MS:
            raise ValueError("Use complete excerpts up to 180 seconds; long-recording performance is not qualified")
        for kind in ("audio", "transcript"):
            if digest(source[kind + "Path"]) != source[kind + "SHA256"]:
                raise ValueError("Changed comparison input")
        with wave.open(source["audioPath"], "rb") as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                raise ValueError("Prepare mono PCM16 / 16 kHz WAV first")
            if abs(audio.getnframes() / 16 - source["durationMs"]) > 1:
                raise ValueError("Duration does not match audio")
        transcript = read(source["transcriptPath"])
        if transcript.get("schemaVersion") != 1:
            raise ValueError("Unsupported primary transcript schema")
        units(transcript["segments"], source["durationMs"])


def units(segments, duration):
    """Retain true word times where available; never interpolate phrase times."""
    result = []
    previous_start = -1
    for segment in segments:
        start, end = segment["startMs"], segment["endMs"]
        if (not isinstance(start, int) or not isinstance(end, int)
                or not 0 <= start <= end <= duration or start < previous_start):
            raise ValueError("Invalid segment timeline")
        previous_start = start
        words = segment.get("words", [])
        if words and tokens(" ".join(w["text"] for w in words)) != tokens(segment["text"]):
            raise ValueError("Primary word layer does not match text")
        last_word = start
        for word in words or [segment]:
            ws, we = word["startMs"], word["endMs"]
            if not isinstance(ws, int) or not isinstance(we, int) or not start <= ws <= we <= end or ws < last_word:
                raise ValueError("Invalid word timeline")
            last_word = ws
            result.extend(dict(text=t, startMs=ws, endMs=we, uncertain=segment.get("uncertain", False),
                               timing="word" if words else "phrase") for t in tokens(word["text"]))
    return result


def compatible(a, b):
    return a["startMs"] <= b["endMs"] + TIME_TOLERANCE_MS and b["startMs"] <= a["endMs"] + TIME_TOLERANCE_MS


def compare(primary, captions, duration):
    original = units(primary, duration)
    alternate = units(captions, duration)
    a, b = [w["text"] for w in original], [w["text"] for w in alternate]
    opcodes = difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes()
    differences = []
    for index, (kind, i, j, k, l) in enumerate(opcodes):
        if kind == "equal":
            continue
        reasons = []
        before = opcodes[index - 1] if index else None
        after = opcodes[index + 1] if index + 1 < len(opcodes) else None
        anchored = (before is not None and after is not None
                    and before[0] == after[0] == "equal"
                    and before[2] - before[1] >= ANCHOR_WORDS and after[2] - after[1] >= ANCHOR_WORDS)
        if not anchored:
            reasons.append("insufficientAnchors")
        elif not all(compatible(original[x], alternate[y]) for x, y in
                     [(i - 1, k - 1), (i - 2, k - 2), (j, l), (j + 1, l + 1)]):
            reasons.append("timingMismatch")
        if max(j - i, l - k) > MAX_DIFFERENCE_WORDS:
            reasons.append("broadDifference")
        if k == l:
            reasons.append("captionOmissionCannotDeletePrimary")
        selected = original[i:j] or alternate[k:l]
        sensitive = any(re.search(r"[a-z0-9]", w) or w in ("не", "нет", "not", "no", "never") for w in a[i:j] + b[k:l])
        differences.append(dict(kind=kind, primaryTokenRange=[i, j], captionTokenRange=[k, l],
                                primary=" ".join(a[i:j]), caption=" ".join(b[k:l]),
                                startMs=min(w["startMs"] for w in selected), endMs=max(w["endMs"] for w in selected),
                                reason="primaryOmissionCandidate" if i == j else
                                       "uncertainPrimary" if any(w["uncertain"] for w in original[i:j]) else "disagreement",
                                sensitive=sensitive, eligibleForReview=not reasons, rejectedBecause=reasons,
                                captionTiming="phrase", automaticEdit=False))
    return dict(primaryTokens=a, captionTokens=b, differences=differences)


def score(comparison, reference):
    expected = tokens(reference)
    original, alternate = comparison["primaryTokens"], comparison["captionTokens"]
    baseline = word_errors(expected, original)
    baseline_errors = sum(baseline[k] for k in ("substitutions", "deletions", "insertions"))
    simulated = original[:]
    eligible_effects = dict(improved=0, worsened=0, sameErrorCount=0)
    for candidate in comparison["differences"]:
        i, j = candidate["primaryTokenRange"]
        k, l = candidate["captionTokenRange"]
        changed = word_errors(expected, original[:i] + alternate[k:l] + original[j:])
        delta = sum(changed[key] for key in ("substitutions", "deletions", "insertions")) - baseline_errors
        candidate["individualErrorDelta"] = delta
        if candidate["eligibleForReview"]:
            eligible_effects["improved" if delta < 0 else "worsened" if delta > 0 else "sameErrorCount"] += 1
    for candidate in reversed(comparison["differences"]):
        if candidate["eligibleForReview"]:
            i, j = candidate["primaryTokenRange"]
            k, l = candidate["captionTokenRange"]
            simulated[i:j] = alternate[k:l]
    return dict(primary=baseline, captions=word_errors(expected, alternate),
                hypotheticalAllReviewCandidates=word_errors(expected, simulated), eligibleEffects=eligible_effects)


def evaluate(root, references=None):
    spec = read(root / "input.json")
    validate_input(spec)
    reference_by_id = {}
    if references is not None:
        if references.get("schemaVersion") != 1:
            raise ValueError("Unsupported reference schema")
        for ref in references["sources"]:
            if ref["id"] in reference_by_id or ref.get("verified") is not True or not ref.get("provenance"):
                raise ValueError("Reference must be unique, verified, and have provenance")
            reference_by_id[ref["id"]] = ref
    report = dict(schemaVersion=1, algorithm=VERSION, automaticEdits=False, sources=[],
                  limitations=["continuous replay, not live microphone acceptance", "phrase timing for captions, no word confidence",
                               "difference is not proof of an ASR error", "no quality claim without a verified reference"])
    for source in spec["sources"]:
        native = read(root / "captions" / (source["id"] + ".json"))
        if (native.get("schemaVersion") != 1 or native["source"] != source or native["speed"] != spec["speed"]
                or native["droppedBuffers"] != 0 or abs(native["consumedFrames"] / 16 - source["durationMs"]) > 1):
            raise ValueError("Incomplete or mismatched native replay")
        comparison = compare(read(source["transcriptPath"])["segments"], native["segments"], source["durationMs"])
        row = dict(id=source["id"], durationMs=source["durationMs"], audioSHA256=source["audioSHA256"],
                   transcriptSHA256=source["transcriptSHA256"], language=source["language"],
                   replayElapsedSeconds=native["elapsedSeconds"], readyAfterSeconds=native["readyAfterSeconds"],
                   replaySpeed=native["speed"], unfinishedPhrases=native["unfinishedPhrases"], **comparison)
        if source["id"] in reference_by_id:
            ref = reference_by_id[source["id"]]
            if ref["audioSHA256"] != source["audioSHA256"]:
                raise ValueError("Reference belongs to different audio")
            row["scores"] = score(comparison, ref["text"])
        report["sources"].append(row)
    return report


def markdown(report):
    lines = ["# Сверка предрасшифровки — эксперимент", "", "Автоматических изменений архива: 0.", "",
             "Непрерывный повтор готового аудио; границы Apple Speech относятся к фразам. Расхождение не доказывает ошибку.", ""]
    for row in report["sources"]:
        candidates = row["differences"]
        lines += [f"## {row['id']} ({row['durationMs'] / 1000:.3f} с)", "",
                  f"Расхождений: {len(candidates)}; для проверки: {sum(c['eligibleForReview'] for c in candidates)}. "
                  f"Незавершённых фраз исключено: {row['unfinishedPhrases']}.", "",
                  f"Повтор ×{row['replaySpeed']:g}: {row['replayElapsedSeconds']:.3f} с, включая подачу звука и подготовку Speech. "
                  "Это не замер добавочной задержки финального ASR.", ""]
        if "scores" in row:
            s = row["scores"]
            def wer(value):
                return f"{value:.2%}" if value is not None else "нет слов в эталоне"
            lines += [f"WER: основная {wer(s['primary']['wer'])}; Apple {wer(s['captions']['wer'])}; "
                      f"гипотетическое применение всех кандидатов {wer(s['hypotheticalAllReviewCandidates']['wer'])}.", "",
                      f"Отдельные кандидаты: {s['eligibleEffects']}. Равное число ошибок не означает правильную замену.", ""]
        for c in candidates:
            # User text is untrusted Markdown: render as indented code, never HTML.
            lines += [f"- {c['startMs'] / 1000:.2f}–{c['endMs'] / 1000:.2f} с; "
                      f"{'проверить' if c['eligibleForReview'] else 'отклонён'}; {c['reason']}; "
                      f"Δ ошибок: {c.get('individualErrorDelta', 'нет эталона')}", "",
                      "    Основная: " + c["primary"], "", "    В эфире: " + c["caption"], ""]
    return "\n".join(lines)


def validate_completed(root):
    spec = read(root / "input.json")
    completion = read(root / "completed.json")
    freeze = read(root / "freeze.json")
    current_input = digest(root / "input.json")
    if (completion["inputSHA256"] != current_input or freeze["inputSHA256"] != current_input
            or set(completion["captions"]) != {s["id"] for s in spec["sources"]}):
        raise ValueError("Incomplete or changed replay input")
    for key, value in completion["captions"].items():
        if digest(root / "captions" / (key + ".json")) != value:
            raise ValueError("Replay output changed")


def launch(root, bundle, timeout):
    environment = process_environment()
    environment["LOCALSCRIBE_CAPTION_COMPARISON"] = str(root)
    child = subprocess.Popen(["xcrun", "xctest", "-XCTest",
                              "LocalScribeUITests.LiveCaptionComparisonProbeTests/testExplicitLiveCaptionComparisonProbe", str(bundle)],
                             cwd=REPO, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        code = child.wait(timeout=timeout)
    except BaseException:
        # Stop the entire process group; do not leave a recognizer after a timeout.
        import os
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        raise
    if code:
        raise RuntimeError(f"Speech replay failed (exit {code}); partial output must not be evaluated")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--test-bundle", type=pathlib.Path)
    parser.add_argument("--reference", type=pathlib.Path)
    parser.add_argument("--speed", type=float, default=4)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--score-only", action="store_true")
    args = parser.parse_args()
    root = args.output.resolve()
    if not root.is_relative_to((REPO / "TestResults").resolve()) or root == (REPO / "TestResults").resolve():
        raise ValueError("Use a separate experiment directory inside TestResults")
    if not args.score_only:
        if root.exists() or args.input is None or not math.isfinite(args.speed) or not 1 <= args.speed <= 8:
            raise ValueError("Supply --input, speed 1–8, and a fresh --output directory")
        spec = read(args.input)
        validate_input(spec)
        # Drop any unrelated fields, especially references, before invoking Speech.
        keys = ("id", "audioPath", "audioSHA256", "transcriptPath", "transcriptSHA256", "durationMs", "language")
        spec = dict(schemaVersion=1, speed=args.speed, sources=[{key: s[key] for key in keys} for s in spec["sources"]])
        if args.test_bundle is None:
            subprocess.run(["swift", "test", "-c", "release", "-j", "4", "--force-resolved-versions", "--filter",
                            "LiveCaptionComparisonProbeTests"], cwd=REPO, env=process_environment(), check=True)
            binary_dir = subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"],
                                                 cwd=REPO, env=process_environment(), text=True).strip()
            bundle = pathlib.Path(binary_dir) / "LocalScribeUITests.xctest"
        else:
            bundle = args.test_bundle.resolve()
        binary = bundle / "Contents/MacOS/LocalScribeUITests"
        if not binary.is_file():
            raise ValueError("Supply built LocalScribeUITests.xctest")
        code_paths = ["scripts/probe_live_caption_comparison.py", "scripts/probe_asr_matrix.py",
                      "Tests/LocalScribeUITests/LiveCaptionComparisonProbeTests.swift",
                      "Sources/LocalScribe/LiveCaptionRecognition.swift", "Sources/LocalScribe/BilingualCaptionResults.swift",
                      "Package.resolved"]
        root.mkdir(mode=0o700, parents=True)
        write(root / "input.json", spec)
        for path in code_paths:
            destination = root / "source-snapshot" / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / path, destination)
        write(root / "freeze.json", dict(algorithm=VERSION, macOS=platform.mac_ver()[0], machine=platform.machine(),
                                          inputSHA256=digest(root / "input.json"), binarySHA256=digest(binary),
                                          code={p: digest(REPO / p) for p in code_paths}, referenceUsedForSelection=False,
                                          maxDifferenceWords=MAX_DIFFERENCE_WORDS, anchorWords=ANCHOR_WORDS,
                                          timeToleranceMs=TIME_TOLERANCE_MS))
        started = time.monotonic()
        launch(root, bundle, args.timeout)
        write(root / "completed.json", dict(inputSHA256=digest(root / "input.json"), elapsedSeconds=time.monotonic() - started,
                                              captions={s["id"]: digest(root / "captions" / (s["id"] + ".json")) for s in spec["sources"]}))
    validate_completed(root)
    report = evaluate(root, read(args.reference) if args.reference else None)
    report["scoringCodeSHA256"] = digest(pathlib.Path(__file__))
    report["referenceSHA256"] = digest(args.reference) if args.reference else None
    write(root / "comparison.json", report)
    markdown_path = root / "comparison.md"
    markdown_path.write_text(markdown(report), encoding="utf-8")
    markdown_path.chmod(0o600)
    print(f"Completed {len(report['sources'])} sources; automatic edits: 0; report: {root / 'comparison.md'}")


if __name__ == "__main__":
    main()
