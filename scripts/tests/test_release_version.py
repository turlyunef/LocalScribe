"""Keep release metadata in sync across the app, service and CLI fallback."""

from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseVersionTests(unittest.TestCase):
    def test_release_metadata_agrees(self):
        with (ROOT / "Resources/Info.plist").open("rb") as file:
            app = plistlib.load(file)
        with (ROOT / "Resources/ModelService-Info.plist").open("rb") as file:
            service = plistlib.load(file)
        app_info = (ROOT / "Sources/LocalScribe/AppInfo.swift").read_text()
        readme = (ROOT / "README.md").read_text()
        version = re.search(r"Текущая версия — (\d+\.\d+\.\d+)\.", readme)
        self.assertIsNotNone(version)
        self.assertEqual(app["CFBundleShortVersionString"], version.group(1))
        self.assertEqual(app["CFBundleVersion"], service["CFBundleVersion"])
        self.assertEqual(service["CFBundleShortVersionString"], app["CFBundleShortVersionString"])
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            fallback = re.search(rf'"{key}"\) as\? String \?\? "([^"]+)"', app_info)
            self.assertIsNotNone(fallback)
            self.assertEqual(fallback.group(1), app[key])
