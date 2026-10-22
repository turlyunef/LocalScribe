import importlib.util
import itertools
import pathlib
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("score_asr_control", SCRIPTS / "score_asr_control.py")
score = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(score)


class WholeClipControlScoringTests(unittest.TestCase):
    def unit(self, name, start, end, original, candidate, proposed):
        return {"id": name, "startMs": start, "endMs": end, "partialTargetUnsupported": False,
                "texts": {"A": original, "C": original, "repeat": candidate, "proposed": proposed}}

    def test_whole_clip_projects_disjoint_units_without_repeating_original_words(self):
        units = [self.unit("left", 0, 100, "one", "one", "one"),
                 self.unit("target", 100, 300, "old", "new", "fixed"),
                 self.unit("right", 300, 500, "last", "last", "last")]
        texts, ids = score.project(units, 0, 500)
        self.assertEqual(ids, ["left", "target", "right"])
        self.assertEqual(texts["repeat"], "one new last")
        self.assertEqual(texts["proposed"], "one fixed last")
        self.assertEqual(texts["C"], "one old last")

    def test_partial_target_and_gaps_are_rejected(self):
        units = [self.unit("a", 0, 100, "one", "one", "one"), self.unit("b", 100, 300, "old", "new", "fixed")]
        with self.assertRaises(ValueError):
            score.project(units, 0, 200)
        units[1]["startMs"] = 110
        with self.assertRaises(ValueError):
            score.project(units, 0, 300)

    def test_unknown_markers_never_become_verified_reference_words(self):
        for marker in ("[не разборчиво]", "[неразборчиво]", "[смех]"):
            interval = {"text": f"one {marker} two", "strictScoringEligible": True}
            with self.assertRaises(ValueError):
                score.exclusion(interval)
            interval["strictScoringEligible"] = False
            self.assertIsNotNone(score.exclusion(interval))

    def test_alignment_audit_agrees_with_fixed_matrix_tie_policy(self):
        sequences = [list(words) for n in range(4) for words in itertools.product(("a", "b"), repeat=n)]
        for reference in sequences:
            for hypothesis in sequences:
                expected = score.matrix.word_errors(reference, hypothesis)
                audit = score.alignment(reference, hypothesis)
                for operation, key in (("S", "substitutions"), ("D", "deletions"), ("I", "insertions")):
                    self.assertEqual(sum(item["operation"] == operation for item in audit), expected[key])

    def test_macro_reference_scores_all_variants_and_excludes_unresolved_clip(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            write = score.matrix.write
            write(root / "input.json", {"sourceHash": "sha", "waveHash": "wave"})
            write(root / "frozen-plan.json", {"durationMs": 600})
            write(root / "E/selective-info.json", {"networkDenied": True})
            units = [self.unit("left", 0, 100, "one", "one", "one"),
                     self.unit("target", 100, 300, "old", "new", "fixed"),
                     self.unit("unknown", 300, 600, "three", "three", "three")]
            write(root / "control-comparison.json", {"sourceHash": "sha", "contextStatus": "completed", "units": units})
            for label in ("A", "C"):
                write(root / label / "transcript.json", {"segments": [
                    {"text": "one", "startMs": 0, "endMs": 100, "words": []},
                    {"text": "old", "startMs": 100, "endMs": 300, "words": []},
                    {"text": "three", "startMs": 300, "endMs": 600, "words": []}]})
            reference = {"schemaVersion": 1, "sourceHash": "sha", "waveHash": "wave", "segments": [
                {"id": "known", "startMs": 0, "endMs": 300, "text": "one new", "verified": True, "verifiedBy": "fixture"},
                {"id": "unresolved", "startMs": 300, "endMs": 600, "text": "three [не разборчиво]", "verified": True,
                 "verifiedBy": "fixture", "strictScoringEligible": False}]}
            result = score.evaluate(root, reference)
            self.assertEqual(result["strictScoredClips"], 1)
            self.assertEqual(result["totals"]["A"]["referenceWords"], 2)
            self.assertEqual(result["totals"]["A"]["speechWER"], 0.5)
            self.assertEqual(result["totals"]["repeat"]["speechWER"], 0)
            self.assertTrue(all(value is None for value in result["clips"][1]["scores"].values()))
            self.assertEqual(result["newModelCalls"], 0)
            self.assertEqual(reference["segments"][1]["text"], "three [не разборчиво]")

    def test_nonlexical_aliases_and_fillers_are_not_silently_normalized(self):
        self.assertEqual(score.matrix.tokens("k 8 s"), ["k", "8", "s"])
        self.assertNotEqual(score.matrix.tokens("k8s"), score.matrix.tokens("k 8 s"))
        self.assertNotEqual(score.matrix.tokens("э one"), score.matrix.tokens("one"))


if __name__ == "__main__":
    unittest.main()
