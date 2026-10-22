#!/usr/bin/env python3
"""Score human whole-clip references against frozen ASR evaluation units.

No inference, word alignment of the reference, or edits to source artifacts.
Only complete unions of previously frozen units can be evaluated. Unknown
speech/laughter without human time bounds excludes the whole reference clip
from strict WER; annotation labels never become reference words.
"""
import argparse
import csv
import pathlib
import re
import shutil

import probe_asr_matrix as matrix

LABELS = ("A", "C", "repeat", "proposed")
ANNOTATION = re.compile(r"\[(?:не\s*разборчиво|смех)\]", re.IGNORECASE)


def alignment(reference, hypothesis):
    """Same local S/D/I tie order as matrix.word_errors, with an audit trail."""
    costs = [[0] * (len(hypothesis) + 1) for _ in range(len(reference) + 1)]
    operations = [[None] * (len(hypothesis) + 1) for _ in range(len(reference) + 1)]
    for i in range(1, len(reference) + 1):
        costs[i][0], operations[i][0] = i, "D"
    for j in range(1, len(hypothesis) + 1):
        costs[0][j], operations[0][j] = j, "I"
    for i, expected in enumerate(reference, 1):
        for j, actual in enumerate(hypothesis, 1):
            if expected == actual:
                costs[i][j], operations[i][j] = costs[i-1][j-1], "="
            else:
                costs[i][j], operations[i][j] = min(
                    [(costs[i-1][j-1] + 1, "S"), (costs[i-1][j] + 1, "D"), (costs[i][j-1] + 1, "I")],
                    key=lambda item: item[0])
    i, j, result = len(reference), len(hypothesis), []
    while i or j:
        operation = operations[i][j]
        result.append({"operation": operation, "reference": reference[i-1] if operation != "I" else "",
                       "hypothesis": hypothesis[j-1] if operation != "D" else ""})
        if operation != "I":
            i -= 1
        if operation != "D":
            j -= 1
    return result[::-1]


def project(units, start, end):
    selected = [unit for unit in units if unit["startMs"] < end and start < unit["endMs"]]
    if not selected or selected[0]["startMs"] != start or selected[-1]["endMs"] != end:
        raise ValueError("Reference must cover complete frozen evaluation units")
    if any(a["endMs"] != b["startMs"] for a, b in zip(selected, selected[1:])):
        raise ValueError("Frozen evaluation units have a gap or overlap")
    if any(unit.get("partialTargetUnsupported") for unit in selected):
        raise ValueError("Cannot slice a timing-free proposal")
    # These are disjoint, already owned scoring units, not concatenated Segment
    # arrays or edits applied by tmp IDs. No Transcript is constructed/published.
    return {label: " ".join(unit["texts"][label] for unit in selected).strip() for label in LABELS}, [unit["id"] for unit in selected]


def exclusion(interval):
    eligible = interval.get("strictScoringEligible", True)
    if not isinstance(eligible, bool):
        raise ValueError("strictScoringEligible must be boolean")
    unresolved = bool(ANNOTATION.search(interval["text"])) or bool(interval.get("unresolvedAnnotations"))
    if unresolved and eligible:
        raise ValueError("Unresolved annotation must be explicitly excluded from strict WER")
    if not eligible:
        return interval.get("strictScoringExclusionReason", "Explicitly excluded from strict WER")
    return None


def evaluate(source, reference):
    input_info = matrix.read(source / "input.json")
    plan = matrix.read(source / "frozen-plan.json")
    frozen = matrix.read(source / "control-comparison.json")
    info = matrix.read(source / "E/selective-info.json")
    if frozen["sourceHash"] != input_info["sourceHash"] or frozen["contextStatus"] != "completed" or not info["networkDenied"]:
        raise ValueError("Need a completed frozen context experiment")
    if reference.get("waveHash") != input_info["waveHash"]:
        raise ValueError("Reference WAV SHA does not match")
    intervals = matrix.reviewed_intervals(reference, input_info["sourceHash"], plan["durationMs"])
    scores, rows = {label: [] for label in LABELS}, []
    transcripts = {label: matrix.read(source / label / "transcript.json") for label in ("A", "C")}
    for interval in intervals:
        if interval.get("kind", "speech") != "speech":
            raise ValueError("This whole-clip scorer requires speech references; use timed nonSpeech scoring separately")
        texts, units = project(frozen["units"], interval["startMs"], interval["endMs"])
        for label in ("A", "C"):
            if matrix.tokens(texts[label]) != matrix.tokens(matrix.interval_text(transcripts[label], interval["startMs"], interval["endMs"])):
                raise ValueError("Frozen partition changes the baseline token sequence")
        reason = exclusion(interval)
        row = {"id": interval["id"], "startMs": interval["startMs"], "endMs": interval["endMs"],
               "referenceText": interval["text"], "strictExclusionReason": reason,
               "unitIDs": units, "hypotheses": texts, "scores": {}, "alignments": {}}
        for label, text in texts.items():
            if reason:
                row["scores"][label] = None
                continue
            score = matrix.score_interval(interval, text)
            audit = alignment(matrix.tokens(interval["text"]), matrix.tokens(text))
            if [sum(a["operation"] == op for a in audit) for op in ("S", "D", "I")] != [score[key] for key in ("substitutions", "deletions", "insertions")]:
                raise ValueError("Alignment and scorer disagree")
            row["scores"][label], row["alignments"][label] = score, audit
            scores[label].append(score)
        rows.append(row)
    return {"schemaVersion": 1, "scope": "human-reviewed-control-clips-only", "sourceHash": input_info["sourceHash"],
            "waveHash": input_info["waveHash"], "newModelCalls": 0, "prototypeRetuned": False,
            "qualityStatus": "partial-reviewed-reference" if any(scores.values()) else "awaiting-complete-reference",
            "reviewedClips": len(rows), "strictScoredClips": sum(not row["strictExclusionReason"] for row in rows),
            "strictScoredDurationMs": sum(row["endMs"] - row["startMs"] for row in rows if not row["strictExclusionReason"]),
            "nonSpeechStatus": "not-evaluated-no-timed-human-nonSpeech-reference",
            "totals": {label: matrix.aggregate_scores(values) for label, values in scores.items()}, "clips": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path, required=True)
    parser.add_argument("--reference", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    source, reference_path, output = args.source.resolve(), args.reference.resolve(), args.output.resolve()
    if output.exists() or not output.is_relative_to(matrix.REPO / "TestResults") or output.is_relative_to(source) or source.is_relative_to(output):
        parser.error("Need a separate fresh output directory under TestResults")
    manifest = matrix.read(source / "artifact-hashes.json")
    for name, record in manifest["files"].items():
        if matrix.digest(source / name) != record["sha256"]:
            raise ValueError("Frozen source artifact changed")
    reference = matrix.read(reference_path)
    result = evaluate(source, reference)
    output.mkdir(parents=True, mode=0o700)
    shutil.copy2(reference_path, output / "reference.user-verbatim.json")
    names = ["input.json", "control-comparison.json", "frozen-plan.json", "artifact-hashes.json", "prototype-freeze.json",
             "E/selective-info.json", "E/metrics-asr.json", "A/transcript.json", "C/transcript.json"]
    names += [str(path.relative_to(source)) for path in sorted((source / "E/context-reviews").glob("*.json"))]
    source_hashes = {name: matrix.digest(source / name) for name in names}
    result["referenceSHA256"] = matrix.digest(reference_path)
    result["scorerSourceHashes"] = {"scripts/score_asr_control.py": matrix.digest(__file__),
                                    "scripts/probe_asr_matrix.py": matrix.digest(matrix.__file__)}
    matrix.write(output / "scores.json", result)
    lines = ["# Первая ручная оценка замороженного контроля", "",
             f"Строгий WER: {result['strictScoredClips']} из {result['reviewedClips']} фрагментов; техническая речь с неразмеченными по времени неразборчивыми местами/смехом исключается целиком. Текст пользователя сохранён дословно.", "",
             "| Вариант | Эталонных слов | S | D | I | WER речи |", "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for label, total in result["totals"].items():
        wer = "не определён" if total["speechWER"] is None else f"{total['speechWER']:.2%}"
        lines.append(f"| {label} | {total['referenceWords']} | {total['substitutions']} | {total['deletions']} | {total['insertions']} | {wer} |")
    lines += ["", "Это показатели выбранных интервалов, не всей встречи. Формы k 8 s, https, слова-паразиты и повторы не исправляются автоматически; нормализация та же, что в матрице. Полные английские реплики этим набором не проверены.", ""]
    with (output / "alignments.tsv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(["clip", "variant", "operation", "reference", "hypothesis"])
        for row in result["clips"]:
            lines += [f"## {row['id']} · {matrix.timecode(row['startMs'])}–{matrix.timecode(row['endMs'])}", "",
                      "**Ручной ответ:** " + row["referenceText"], ""]
            if row["strictExclusionReason"]:
                lines += ["Строгий WER исключён: " + row["strictExclusionReason"], ""]
            for label, text in row["hypotheses"].items():
                score = row["scores"][label]
                suffix = "" if score is None else f" (WER {score['wer']:.2%}, S/D/I {score['substitutions']}/{score['deletions']}/{score['insertions']})"
                lines += [f"**{label}{suffix}:** {text or '[нет текста]'}", ""]
                for item in row["alignments"].get(label, []):
                    writer.writerow([row["id"], label, item["operation"], item["reference"], item["hypothesis"]])
    (output / "full-comparison.md").write_text("\n".join(lines), encoding="utf-8")
    for name in result["scorerSourceHashes"]:
        destination = output / "source-snapshot" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(matrix.REPO / name, destination)
    if any(matrix.digest(source / name) != sha for name, sha in source_hashes.items()) or matrix.digest(reference_path) != result["referenceSHA256"]:
        raise ValueError("Source hypotheses or human reference changed")
    matrix.write(output / "provenance.json", {"sourceDirectory": str(source), "referencePath": str(reference_path),
        "referenceSHA256": result["referenceSHA256"], "frozenInputHashes": source_hashes,
        "scorerSourceHashes": result["scorerSourceHashes"], "newModelCalls": 0, "originalArtifactsUnchanged": True})
    print({"strictScoredClips": result["strictScoredClips"], "referenceWords": result["totals"]["A"]["referenceWords"],
           "WER": {label: total["speechWER"] for label, total in result["totals"].items()}, "newModelCalls": 0})


if __name__ == "__main__":
    main()
