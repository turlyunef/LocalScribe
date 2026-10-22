#!/usr/bin/env python3
"""Session 4 disclosed-data probe. Reference text never enters the Swift model input.

Prepare from a completed session-3 directory, then run plan/offline/live/retries
in that order. All transcript artifacts stay in an explicit TestResults folder.
"""
import argparse
import copy
import os
import pathlib
import shutil
import signal
import subprocess
import time

import probe_asr_matrix as matrix
import score_asr_control_masks as masks


def prepare(root, previous):
    if root.exists():
        raise ValueError("Preparation needs a fresh directory")
    old = matrix.read(previous / "settings-input.json")
    sources = [copy.deepcopy(s) for s in old["sources"] if s["id"] in ("control", "short-ru")]
    payment = next(s for s in old["sources"] if s["id"] == "payment")
    next(s for s in sources if s["id"] == "control")["intervals"] += payment["intervals"]
    for source in sources:
        if matrix.digest(pathlib.Path(source["wavePath"])) != source["waveHash"]:
            raise ValueError("Changed disclosed PCM")
    root.mkdir(parents=True)
    matrix.write(root / "boundary-input.json", {**old, "sources": sources, "lexicon": ""})
    evaluation = matrix.read(previous / "settings-evaluation.json")
    evaluation["sources"] = [s for s in evaluation["sources"] if s["id"] in ("control", "payment", "short-ru")]
    for source in evaluation["sources"]:
        source["inferenceSourceID"] = "control" if source["id"] == "payment" else source["id"]
        dest = root / "references" / (source["id"] + ".json")
        dest.parent.mkdir(exist_ok=True)
        shutil.copy2(source["referencePath"], dest)
        source["referencePath"] = str(dest)
    matrix.write(root / "boundary-evaluation.json", evaluation)
    retries = []
    for name, target, ranges in [
        ("figma", (158000, 179000), [(149000, 179000), (154000, 184000), (158000, 179000)]),
        ("late-speech", (408370, 423000), [(393000, 423000), (401000, 431000), (408370, 438370)]),
        ("noise-and-neighbors", (470000, 481930), [(455000, 485000), (460000, 490000), (465000, 495000)]),
    ]:
        for index, (start, end) in enumerate(ranges):
            retries.append(dict(id=f"{name}-{index}", sourceID="control", startMs=start, endMs=end,
                targetStartMs=target[0], targetEndMs=target[1]))
    matrix.write(root / "retry-plan.json", retries)
    paths = ["Sources/LocalScribeCore/Analysis.swift", "Sources/LocalScribeWorker/SpeechRecognizer.swift",
        "Sources/LocalScribeWorker/LiveTranscriber.swift", "Sources/LocalScribeWorker/ASRContextReview.swift",
        "Sources/LocalScribeWorker/ASRWordRepair.swift", "Sources/LocalScribeCore/Contracts.swift",
        "Tests/LocalScribeDiarizationTests/ASRBoundaryProbeTests.swift", "scripts/probe_asr_boundaries.py",
        "Package.swift", "Package.resolved"]
    hashes = {}
    for name in paths:
        dest = root / "source-snapshot" / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(matrix.REPO / name, dest)
        hashes[name] = matrix.digest(dest)
    matrix.write(root / "pre-inference-freeze.json", {"sourceSession": str(previous), "code": hashes,
        "inputSHA256": matrix.digest(root / "boundary-input.json"),
        "retryPlanSHA256": matrix.digest(root / "retry-plan.json"), "finalHoldoutUsed": False,
        "maxRetriesPerTarget": 3, "recursiveRetries": False,
        "scope": "selected windows on disclosed real PCM; closed-CAF availability replay, not microphone acceptance"})


def evaluate(root, label):
    by_source = {}
    plan = matrix.read(root / f"{label}-plan.json")
    paths = sorted((root / label / "windows").glob("*.json"), key=lambda p: int(p.stem))
    if [int(path.stem) for path in paths] != list(range(len(plan))):
        raise ValueError("Incomplete boundary variant")
    for index, path in enumerate(paths):
        output = matrix.read(path)
        if output["window"] != plan[index]:
            raise ValueError("Changed boundary plan")
        by_source.setdefault(output["window"]["sourceID"], []).extend(output["segments"])
    scores = {}
    for source in matrix.read(root / "boundary-evaluation.json")["sources"]:
        reference = matrix.read(source["referencePath"])
        matrix.reviewed_intervals(reference, source["sourceHash"], source["durationMs"])
        transcript = {"segments": by_source[source["inferenceSourceID"]]}
        rows, totals = [], []
        for interval in reference["segments"]:
            if not interval.get("verified"):
                continue
            if interval.get("kind") == "nonSpeech" or interval.get("wordBoundaryTruncated"):
                spans = [interval]
            else:
                verified, _ = masks.verified_masks(interval)
                spans = [{**interval, **span} for span in masks.known_spans(interval, verified)]
            for span in spans:
                score = matrix.score_transcript_interval(span, transcript)
                rows.append({"id": interval["id"], "reference": span["text"],
                    "hypothesis": matrix.interval_text(transcript, span["startMs"], span["endMs"]),
                    "startMs": span["startMs"], "endMs": span["endMs"], **score})
                totals.append(score)
        scores[source["id"]] = {"totals": matrix.aggregate_scores(totals), "intervals": rows}
    return scores


def launch(bundle, root, label, timeout):
    env = matrix.process_environment()
    env.update(LOCALSCRIBE_ASR_BOUNDARY_PROBE="technical-probe", LOCALSCRIBE_ASR_MATRIX_OUTPUT=str(root),
        LOCALSCRIBE_ASR_BOUNDARY_VARIANT=label)
    started = time.monotonic()
    child = subprocess.Popen(["xcrun", "xctest", "-XCTest",
        "LocalScribeDiarizationTests.ASRBoundaryProbeTests/testExplicitBoundaryProbe", str(bundle)],
        cwd=matrix.REPO, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        code = child.wait(timeout=timeout)
    except BaseException:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        raise
    matrix.write(root / f"runtime-{label}.json", {"returncode": code, "wallSeconds": time.monotonic() - started,
        "binarySHA256": matrix.digest(bundle / "Contents/MacOS/LocalScribeDiarizationTests")})
    if code:
        raise RuntimeError(f"Boundary probe {label} failed; SDK output discarded")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--prepare-from", type=pathlib.Path)
    parser.add_argument("--test-bundle", type=pathlib.Path)
    parser.add_argument("--variants", nargs="+", choices=["plan", "offline", "live", "retries"], default=[])
    parser.add_argument("--timeout", type=int, default=7200)
    parser.add_argument("--score-only", action="store_true")
    args = parser.parse_args()
    root = args.output.resolve()
    if not root.is_relative_to(matrix.REPO / "TestResults"):
        raise ValueError("Explicit artifacts must stay in TestResults")
    if args.prepare_from:
        prepare(root, args.prepare_from.resolve())
    if args.variants:
        bundle = matrix.test_bundle(args.test_bundle)
        for label in args.variants:
            print(f"Starting {label}", flush=True)
            launch(bundle, root, label, args.timeout)
            print(f"Completed {label}", flush=True)
    scores = {}
    for label in ["offline", "live"]:
        if (root / label / "validation.json").exists():
            scores[label] = evaluate(root, label)
    if scores:
        matrix.write(root / "scores.json", scores)


if __name__ == "__main__":
    main()
