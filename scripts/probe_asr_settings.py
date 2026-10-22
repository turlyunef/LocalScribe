#!/usr/bin/env python3
"""Run explicit session-3 probes and score frozen A inputs; never opens holdout data.

Prepare settings-input.json and settings-evaluation.json in a new TestResults
directory first. Reference text is used by this scorer only, not the model test.
"""
import argparse
import pathlib
import subprocess
import time
import os
import signal

import probe_asr_matrix as matrix
import score_asr_control_masks as masks


def evaluate(root, label, preserve=False):
    config = matrix.read(root / "settings-evaluation.json")
    plan = matrix.read(root / "settings-plan.json")
    by_source = {source["id"]: [] for source in config["sources"]}
    for index, window in enumerate(plan):
        path = root / label / "windows" / f"{index}.json"
        if path.exists():
            output = matrix.read(path)
            if output["window"] != window:
                raise ValueError("Changed frozen input")
            by_source[window["sourceID"]] += output["preserved" if preserve else "segments"]
        elif label != "retry":
            raise ValueError("Incomplete variant")
        else:
            output = matrix.read(root / "baseline/windows" / f"{index}.json")
            by_source[window["sourceID"]] += output["segments"]
    scores = {}
    for source in config["sources"]:
        reference = matrix.read(source["referencePath"])
        matrix.reviewed_intervals(reference, source["sourceHash"], source["durationMs"])
        rows, total = [], []
        for interval in reference["segments"]:
            if not interval.get("verified"):
                continue
            if interval.get("kind") == "nonSpeech" or interval.get("wordBoundaryTruncated"):
                spans = [interval]
            else:
                verified, _ = masks.verified_masks(interval)
                spans = [{**interval, **span} for span in masks.known_spans(interval, verified)]
            details = []
            for span in spans:
                transcript = {"segments": by_source[source["id"]]}
                text = matrix.interval_text(transcript, span["startMs"], span["endMs"])
                score = matrix.score_transcript_interval(span, transcript)
                details.append({"reference": span["text"], "hypothesis": text,
                    "startMs": span["startMs"], "endMs": span["endMs"], **score})
                total.append(score)
            rows.append({"id": interval["id"], "spans": details})
        scores[source["id"]] = {"kind": source["kind"], "totals": matrix.aggregate_scores(total), "intervals": rows}
    return scores


def launch(bundle, root, label, timeout):
    env = matrix.process_environment()
    env.update(LOCALSCRIBE_ASR_SETTINGS_PROBE="technical-probe",
        LOCALSCRIBE_ASR_MATRIX_OUTPUT=str(root), LOCALSCRIBE_ASR_SETTINGS_VARIANT=label)
    started = time.monotonic()
    child = subprocess.Popen(["xcrun", "xctest", "-XCTest",
        "LocalScribeDiarizationTests.ASRSettingsProbeTests/testExplicitSettingsProbe", str(bundle)],
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
    matrix.write(root / f"runtime-{label}.json", {"returncode": code, "wallSeconds": time.monotonic() - started})
    if code:
        raise RuntimeError(f"Probe {label} failed; SDK output discarded; see failure artifact")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--test-bundle", type=pathlib.Path)
    parser.add_argument("--variants", nargs="+", default=["plan"])
    parser.add_argument("--timeout", type=int, default=7200)
    parser.add_argument("--score-only", action="store_true")
    args = parser.parse_args()
    root = args.output.resolve()
    if not root.is_relative_to(matrix.REPO / "TestResults"):
        raise ValueError("Explicit artifacts must stay in TestResults")
    if not args.score_only:
        bundle = matrix.test_bundle(args.test_bundle)
        for label in args.variants:
            print(f"Starting {label}", flush=True)
            launch(bundle, root, label, args.timeout)
            print(f"Completed {label}", flush=True)
    labels = [p.name for p in root.iterdir() if p.is_dir() and (p / "metrics-asr.json").exists()
              and matrix.read(p / "metrics-asr.json")["status"] == "completed"]
    if labels:
        scores = {label: evaluate(root, label) for label in sorted(labels)}
        scores["preserve-replay"] = evaluate(root, "baseline", preserve=True)
        matrix.write(root / "scores.json", scores)


if __name__ == "__main__":
    main()
