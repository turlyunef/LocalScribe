import importlib.util
import pathlib
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("score_asr_control_masks", SCRIPTS / "score_asr_control_masks.py")
score = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(score)


class HumanMaskScoringTests(unittest.TestCase):
    def mask(self, name="unknown", start=400, end=600, marker="[неразборчиво]", kind="unintelligibleOverlappingSpeech"):
        return {"id": name, "startMs": start, "endMs": end, "marker": marker, "kind": kind,
                "verified": True, "verifiedBy": "fixture-human"}

    def interval(self, text, masks):
        return {"id": "fixture", "startMs": 0, "endMs": 1000, "text": text,
                "kind": "speech", "verified": True, "verifiedBy": "fixture-human",
                "strictScoringEligible": False, "maskedScoringEligible": True, "verifiedMasks": masks}

    def fixture(self, root, hypothesis):
        write = score.matrix.write
        write(root / "input.json", {"sourceHash": "sha", "waveHash": "wave"})
        write(root / "frozen-plan.json", {"durationMs": 1000})
        unit = {"id": "whole", "startMs": 0, "endMs": 1000, "partialTargetUnsupported": False,
                "texts": {label: hypothesis for label in score.control.LABELS}}
        write(root / "control-comparison.json", {"contextStatus": "completed", "units": [unit]})
        for label in ("A", "C"):
            write(root / label / "transcript.json", {"segments": [{"text": hypothesis, "startMs": 600, "endMs": 800,
                  "words": [{"text": hypothesis, "startMs": 600, "endMs": 800}]}]})

    def test_human_marker_order_defines_known_spans_without_asr_alignment(self):
        masks = [self.mask("laugh", 200, 250, "[смех]", "laughter"), self.mask()]
        interval = self.interval("first [смех] middle [неразборчиво] last", masks)
        actual_masks, known = score.verified_masks(interval)
        spans = score.known_spans(interval, actual_masks)
        self.assertEqual(score.matrix.tokens(known), ["first", "middle", "last"])
        self.assertEqual([(s["startMs"], s["endMs"]) for s in spans], [(0, 200), (250, 400), (600, 1000)])

    def test_unverified_masks_and_overlaps_are_rejected(self):
        interval = self.interval("first [неразборчиво] last", [dict(self.mask(), verified=False)])
        with self.assertRaises(ValueError):
            score.verified_masks(interval)
        interval = self.interval("first [смех] [неразборчиво] last", [self.mask("laugh", 200, 500, "[смех]", "laughter"), self.mask()])
        with self.assertRaises(ValueError):
            score.verified_masks(interval)

    def test_incomplete_or_misordered_annotations_cannot_be_silently_removed(self):
        interval = self.interval("first [неразборчиво] [смех] last", [self.mask("laugh", 200, 250, "[смех]", "laughter"), self.mask()])
        masks, _ = score.verified_masks(interval)
        with self.assertRaises(ValueError):
            score.known_spans(interval, masks)
        with self.assertRaises(ValueError):
            score.verified_masks(self.interval("first [неразборчиво] [смех] last", [self.mask()]))

    def test_midpoint_mask_has_inclusive_start_exclusive_end_and_keeps_crossings(self):
        items = [{"text": "start", "startMs": 300, "endMs": 500, "group": "g"},
                 {"text": " end", "startMs": 500, "endMs": 700, "group": "g"}]
        kept, excluded, crossing = score.apply_masks(items, [self.mask()])
        self.assertEqual([w["text"] for w in excluded], ["start"])
        self.assertEqual([w["text"] for w in kept], [" end"])
        self.assertEqual(len(crossing), 2)

    def test_render_preserves_word_pieces_and_segment_boundaries(self):
        items = [{"group": "a", "text": "foo"}, {"group": "a", "text": "bar"}, {"group": "b", "text": " baz"}]
        self.assertEqual(score.render(items), "foobar baz")

    def test_changed_timing_free_proposal_cannot_be_partially_masked(self):
        segment = {"text": "old", "startMs": 0, "endMs": 1000, "words": []}
        unit = {"id": "target", "startMs": 0, "endMs": 1000, "partialTargetUnsupported": False,
                "texts": {"A": "old", "C": "old", "repeat": "old", "proposed": "new"}}
        reviews = {(0, 1000): {"candidate": [segment], "original": [segment],
                              "wordRepair": {"edits": [{}], "proposed": [dict(segment, text="new")]}}}
        with self.assertRaises(ValueError):
            score.project(None, {"units": [unit]}, self.interval("old", []), reviews,
                          {"A": {"segments": [segment]}, "C": {"segments": [segment]}}, [self.mask()])

    def test_alignment_does_not_match_known_words_across_an_unknown_span(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root, "alpha")
            interval = self.interval("alpha [неразборчиво] beta", [self.mask()])
            result = score.evaluate(root, {"schemaVersion": 1, "sourceHash": "sha", "waveHash": "wave", "segments": [interval]})
            # Hypothesis alpha lies after the mask, while reference alpha is before
            # it: D + S, not a free cross-mask match followed by a single deletion.
            self.assertEqual(result["totals"]["A"]["deletions"], 1)
            self.assertEqual(result["totals"]["A"]["substitutions"], 1)
            self.assertEqual(result["totals"]["A"]["speechWER"], 1)
            self.assertFalse(result["unknownSpeechWordsCountedAsNoise"])

    def test_unknown_only_reference_has_null_wer_and_no_fake_zero(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root, "alpha")
            interval = self.interval("[неразборчиво]", [self.mask(start=0, end=1000)])
            result = score.evaluate(root, {"schemaVersion": 1, "sourceHash": "sha", "waveHash": "wave", "segments": [interval]})
            self.assertEqual(result["totals"]["A"]["referenceWords"], 0)
            self.assertIsNone(result["totals"]["A"]["speechWER"])
            self.assertEqual(result["clips"][0]["variants"]["A"]["excludedTokensByMaskKind"]["unintelligibleOverlappingSpeech"], 1)


if __name__ == "__main__":
    unittest.main()
