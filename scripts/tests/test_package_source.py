"""Check the actual tar contents using a tiny isolated source tree."""
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class PackageSourceTests(unittest.TestCase):
    def test_archive_keeps_sources_and_patches_but_omits_git_and_build_outputs(self):
        with tempfile.TemporaryDirectory(prefix="LocalScribe source ") as temporary:
            root = pathlib.Path(temporary)
            (root / "scripts").mkdir()
            shutil.copy2(ROOT / "scripts/package_source.sh", root / "scripts/package_source.sh")
            included = ["Package.swift", "Package.resolved", "Sources/App.swift",
                        "ThirdParty/SpeakerKit/audio-memory.patch", "README.md"]
            excluded = [".git/config", "build/ffmpeg/config.h", ".build/output", ".swiftpm/cache",
                        "Assets/large-model", "TestResults/private.txt", "dist/old.tar.gz", "trace.log",
                        "Vendor/ffmpeg-8.0.1.tar.xz", "Vendor/ffmpeg-8.0.1/configure", "Vendor/new-tool/cache"]
            for name in included + excluded:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture", encoding="utf-8")
            subprocess.run(["bash", str(root / "scripts/package_source.sh")], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            with tarfile.open(root / "dist/LocalScribe-source.tar.gz", "r:gz") as archive:
                names = {name.removeprefix("./") for name in archive.getnames()}
            for name in included:
                self.assertIn(name, names)
            for name in excluded:
                self.assertNotIn(name, names)
            self.assertFalse(any(name == ".git" or name.startswith(".git/") or
                                 name == "build" or name.startswith("build/") for name in names))
            self.assertFalse(any(pathlib.PurePosixPath(name).name.startswith("._") for name in names))
