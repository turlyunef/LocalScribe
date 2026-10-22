#!/usr/bin/env python3
"""Evaluate known speech using human verified time masks, without inference.

Masks remove unknown/nonlexical reference markers and hypothesis units by their
frozen SDK midpoint. Overlapping unintelligible speech is never called silence.
Outputs are evaluation streams; no Transcript or production edit is generated.
"""
import argparse
import pathlib
import re
import shutil

import score_asr_control as control

matrix = control.matrix


def render(records):
    groups = []
    for record in records:
        if not groups or groups[-1][0] != record["group"]:
            groups.append((record["group"], []))
        groups[-1][1].append(record["text"])
    return " ".join("".join(parts).strip() for _, parts in groups if "".join(parts).strip())


def records(segments, start, end, prefix):
    result = []
    for index, segment in enumerate(segments):
        for word_index, word in enumerate(segment.get("words") or [segment]):
            if start <= (word["startMs"] + word["endMs"]) / 2 < end:
                result.append({"text": word["text"], "startMs": word["startMs"], "endMs": word["endMs"],
                    "group": f"{prefix}/segment-{index}", "address": f"{prefix}/segment-{index}/unit-{word_index}",
                    "timingKind": "word" if segment.get("words") else "segment-midpoint-fallback"})
    return result


def verified_masks(interval):
    masks = sorted(interval.get("verifiedMasks", []), key=lambda item: item["startMs"])
    text, previous = interval["text"], interval["startMs"]
    if masks and interval.get("maskedScoringEligible") is not True:
        raise ValueError("Masked reference must explicitly enable known-speech evaluation")
    for mask in masks:
        if mask.get("verified") is not True or not mask.get("verifiedBy", "").strip():
            raise ValueError("Masks require human verification")
        if mask.get("kind") not in {"laughter", "unintelligibleOverlappingSpeech"}:
            raise ValueError("Unsupported mask kind; do not infer silence")
        if not previous <= mask["startMs"] < mask["endMs"] <= interval["endMs"]:
            raise ValueError("Masks overlap or exceed the reference interval")
        if text.count(mask["marker"]) != 1:
            raise ValueError("Each mask must address exactly one human annotation marker")
        text = text.replace(mask["marker"], "", 1)
        previous = mask["endMs"]
    if re.search(r"\[[^\]]+\]", text):
        raise ValueError("Every unresolved annotation needs an explicit verified mask")
    if not masks and control.exclusion(interval):
        raise ValueError("Excluded reference has no verified masks")
    return masks, text


def apply_masks(items, masks):
    kept, excluded, crossing = [], [], []
    for item in items:
        mid = (item["startMs"] + item["endMs"]) / 2
        owned = [mask for mask in masks if mask["startMs"] <= mid < mask["endMs"]]
        for mask in masks:
            if any(item["startMs"] < edge < item["endMs"] for edge in (mask["startMs"], mask["endMs"])):
                crossing.append({"maskID": mask["id"], "excludedByMidpoint": mask["startMs"] <= mid < mask["endMs"], **item})
        if owned:
            excluded.append({"maskID": owned[0]["id"], "maskKind": owned[0]["kind"], **item})
        else:
            kept.append(item)
    return kept, excluded, crossing


def known_spans(interval, masks):
    """Reset alignment at each human unknown/nonlexical span, not ASR words."""
    spans, char_start, time_start = [], 0, interval["startMs"]
    for mask in masks:
        marker_start = interval["text"].find(mask["marker"], char_start)
        if marker_start < 0:
            raise ValueError("Human marker order and time-mask order disagree")
        text = interval["text"][char_start:marker_start]
        if matrix.tokens(text):
            if time_start >= mask["startMs"]:
                raise ValueError("Nonempty known text has no audio span")
            spans.append({"startMs": time_start, "endMs": mask["startMs"], "text": text})
        char_start, time_start = marker_start + len(mask["marker"]), mask["endMs"]
    text = interval["text"][char_start:]
    if matrix.tokens(text):
        if time_start >= interval["endMs"]:
            raise ValueError("Nonempty known text has no audio span")
        spans.append({"startMs": time_start, "endMs": interval["endMs"], "text": text})
    return spans


def project(source, frozen, interval, reviews, transcripts, masks):
    _, selected_ids = control.project(frozen["units"], interval["startMs"], interval["endMs"])
    output = {label: [] for label in control.LABELS}
    for unit in frozen["units"]:
        if unit["id"] not in selected_ids:
            continue
        start, end = unit["startMs"], unit["endMs"]
        review = reviews.get((start, end))
        for label in control.LABELS:
            prefix = f"{label}/{unit['id']}"
            if label in ("A", "C"):
                items = records(transcripts[label]["segments"], start, end, prefix)
            elif review is None:
                items = records(transcripts["C"]["segments"], start, end, prefix)
            elif label == "repeat":
                items = records(review["candidate"], start, end, prefix)
            else:
                repair = review["wordRepair"]
                if not repair["edits"]:
                    if repair["proposed"] != review["original"]:
                        raise ValueError("No-edit proposal differs from its frozen original")
                    items = records(review["original"], start, end, prefix)
                else:
                    if any(mask["startMs"] < end and start < mask["endMs"] for mask in masks):
                        raise ValueError("A changed timing-free proposal cannot be partially masked")
                    items = [{"text": matrix.owned_review_text(repair["proposed"]), "startMs": start, "endMs": end,
                              "group": prefix, "address": prefix, "timingKind": "whole-target-only"}]
            if matrix.tokens(render(items)) != matrix.tokens(unit["texts"][label]):
                raise ValueError("Timestamp projection changes the frozen hypothesis token sequence")
            output[label].extend(items)
    return output, selected_ids


def evaluate(source, reference):
    input_info = matrix.read(source / "input.json")
    frozen = matrix.read(source / "control-comparison.json")
    duration = matrix.read(source / "frozen-plan.json")["durationMs"]
    if reference.get("waveHash") != input_info["waveHash"] or frozen["contextStatus"] != "completed":
        raise ValueError("Reference or frozen experiment identity mismatch")
    intervals = matrix.reviewed_intervals(reference, input_info["sourceHash"], duration)
    transcripts = {label: matrix.read(source / label / "transcript.json") for label in ("A", "C")}
    reviews = {}
    for path in (source / "E/context-reviews").glob("*.json"):
        for review in matrix.read(path)["reviews"]:
            request = review["request"]
            key = (request["startMs"], request["endMs"])
            if key in reviews:
                raise ValueError("Duplicate frozen review target")
            reviews[key] = review
    totals, clips = {label: [] for label in control.LABELS}, []
    for interval in intervals:
        masks, known_text = verified_masks(interval)
        spans = known_spans(interval, masks)
        streams, unit_ids = project(source, frozen, interval, reviews, transcripts, masks)
        row = {"id": interval["id"], "startMs": interval["startMs"], "endMs": interval["endMs"],
               "referenceText": interval["text"], "knownReferenceText": known_text, "verifiedMasks": masks,
               "knownSpans": spans, "unitIDs": unit_ids, "variants": {}}
        for label, stream in streams.items():
            kept, excluded, crossing = apply_masks(stream, masks)
            text = render(kept)
            span_scores, span_details = [], []
            for index, span in enumerate(spans):
                span_items = [item for item in kept if span["startMs"] <= (item["startMs"] + item["endMs"]) / 2 < span["endMs"]]
                hypothesis = render(span_items)
                piece_score = matrix.score_interval(dict(interval, text=span["text"]), hypothesis)
                audit = control.alignment(matrix.tokens(span["text"]), matrix.tokens(hypothesis))
                if [sum(item["operation"] == op for item in audit) for op in ("S", "D", "I")] != [piece_score[key] for key in ("substitutions", "deletions", "insertions")]:
                    raise ValueError("Masked alignment and scorer disagree")
                span_scores.append(piece_score)
                span_details.append({"index": index, **span, "hypothesis": hypothesis, "score": piece_score, "alignments": audit})
            score = dict(matrix.score_interval(dict(interval, text=""), ""), **{
                key: value for key, value in matrix.aggregate_scores(span_scores).items()
                if key in ("referenceWords", "substitutions", "deletions", "insertions", "wer")})
            row["variants"][label] = {"hypothesis": text, "unmaskedHypothesis": render(stream), "score": score,
                "knownSpanScores": span_details, "excludedByHumanMask": excluded, "maskBoundaryCrossings": crossing,
                "excludedTokensByMaskKind": {kind: sum(len(matrix.tokens(item["text"])) for item in excluded if item["maskKind"] == kind)
                    for kind in ("laughter", "unintelligibleOverlappingSpeech")}}
            totals[label].append(score)
        clips.append(row)
    return {"schemaVersion": 1, "scope": "known-speech-with-human-verified-time-masks-only",
        "sourceHash": input_info["sourceHash"], "waveHash": input_info["waveHash"],
        "maskMembership": "SDK word midpoint; segment midpoint fallback explicitly tagged; no forced alignment",
        "alignmentPolicy": "independent known spans; no token alignment across human masks",
        "unknownSpeechWordsCountedAsNoise": False, "laughterOutputCountsProveHallucination": False,
        "newModelCalls": 0, "prototypeRetuned": False, "clips": clips,
        "scoredKnownAudioMs": sum(span["endMs"] - span["startMs"] for row in clips for span in row["knownSpans"]),
        "maskedAudioMs": sum(mask["endMs"] - mask["startMs"] for row in clips for mask in row["verifiedMasks"]),
        "totals": {label: matrix.aggregate_scores(scores) for label, scores in totals.items()}}


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
    result["referenceSHA256"] = matrix.digest(reference_path)
    paths = ("scripts/score_asr_control_masks.py", "scripts/score_asr_control.py", "scripts/probe_asr_matrix.py")
    result["scorerSourceHashes"] = {name: matrix.digest(matrix.REPO / name) for name in paths}
    output.mkdir(parents=True, mode=0o700)
    shutil.copy2(reference_path, output / "reference.user-refined.json")
    matrix.write(output / "scores.json", result)
    lines = ["# Оценка разборчивой речи с ручными временными масками", "",
        "Ручной эталон сохранён дословно. Размеченные человеком интервалы исключены из оценки; неизвестные слова не считаются тишиной. Это WER известной речи с временными масками. Наличие смеха само по себе не доказывает отсутствия одновременной речи.", "",
        "| Вариант | Известных слов | S | D | I | WER |", "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for label, total in result["totals"].items():
        wer = "не определён" if total["speechWER"] is None else f"{total['speechWER']:.2%}"
        lines.append(f"| {label} | {total['referenceWords']} | {total['substitutions']} | {total['deletions']} | {total['insertions']} | {wer} |")
    for row in result["clips"]:
        lines += ["", f"## {row['id']}", "", "**Уточнённый ответ:** " + row["referenceText"], ""]
        for label, variant in row["variants"].items():
            wer = "не определён" if variant["score"]["wer"] is None else f"{variant['score']['wer']:.2%}"
            lines += [f"**{label}, WER {wer}:** {variant['hypothesis'] or '[нет текста]'}", ""]
    (output / "comparison.md").write_text("\n".join(lines), encoding="utf-8")
    for name in paths:
        snapshot = output / "source-snapshot" / name
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(matrix.REPO / name, snapshot)
    for name, record in manifest["files"].items():
        if matrix.digest(source / name) != record["sha256"]:
            raise ValueError("Source changed during scoring")
    if matrix.digest(reference_path) != result["referenceSHA256"]:
        raise ValueError("Human reference changed during scoring")
    matrix.write(output / "provenance.json", {"sourceDirectory": str(source), "sourceManifestSHA256": matrix.digest(source / "artifact-hashes.json"),
        "referencePath": str(reference_path), "referenceSHA256": result["referenceSHA256"],
        "scorerSourceHashes": result["scorerSourceHashes"], "newModelCalls": 0, "sourceArtifactsUnchanged": True})
    print({"knownReferenceWords": result["totals"]["A"]["referenceWords"], "maskedAudioMs": result["maskedAudioMs"],
           "WER": {label: total["speechWER"] for label, total in result["totals"].items()}, "newModelCalls": 0})


if __name__ == "__main__":
    main()
