#!/usr/bin/env python3
"""Five reproducible discovery/document scenarios; tool probes use explicit stubs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import check_document
import discover


def write(root, rel, content):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')
    return path


PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MathKit",
    products: [.library(name: "MathKit", targets: ["MathKit"])],
    targets: [
        .target(name: "MathKit"),
        .testTarget(name: "MathKitTests", dependencies: ["MathKit"])
    ],
    swiftLanguageModes: [.v6]
)
'''


def package_fixture(root):
    write(root, 'Package.swift', PACKAGE)
    write(root, 'Sources/MathKit/Math.swift', 'public func twice(_ value: Int) -> Int { value * 2 }\n')
    write(root, 'Tests/MathKitTests/MathTests.swift', '''import Testing
@testable import MathKit
@Test func doublesPositiveInteger() { #expect(twice(3) == 6) }
''')
    write(root, 'README.md', '''# MathKit
Integer helpers shared by command-line tools. Swift 6 language mode.
Run from the package root: `swift build`, `swift test`.
For one test: `swift test --filter doublesPositiveInteger`.
No external dependencies. Linux compatibility is tested in CI.
''')
    write(root, '.github/workflows/test.yml', '''name: Test
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    container: swift:6.0
    steps:
      - uses: actions/checkout@v4
      - run: swift build
      - run: swift test
''')


def xcode_fixture(root):
    write(root, 'Orbit.xcodeproj/project.pbxproj', '''// !$*UTF8*$!
{
 archiveVersion = 1;
 classes = {};
 objectVersion = 77;
 objects = {
  A00000000000000000000001 = {
   isa = PBXProject;
   attributes = { LastUpgradeCheck = 1600; };
   buildConfigurationList = A00000000000000000000010;
   compatibilityVersion = "Xcode 16.0";
   developmentRegion = en;
   knownRegions = (en, Base);
   mainGroup = A00000000000000000000002;
   productRefGroup = A00000000000000000000003;
   projectDirPath = "";
   projectRoot = "";
   targets = (A00000000000000000000004, A00000000000000000000005);
  };
  A00000000000000000000002 = { isa = PBXGroup; children = (A00000000000000000000006, A00000000000000000000007, A00000000000000000000003); sourceTree = "<group>"; };
  A00000000000000000000003 = { isa = PBXGroup; children = (A00000000000000000000008, A00000000000000000000009); name = Products; sourceTree = "<group>"; };
  A00000000000000000000004 = {
   isa = PBXNativeTarget;
   buildConfigurationList = A00000000000000000000011;
   buildPhases = (A00000000000000000000020);
   buildRules = (); dependencies = ();
   fileSystemSynchronizedGroups = (A00000000000000000000006);
   name = Orbit; productName = Orbit;
   productReference = A00000000000000000000008;
   productType = "com.apple.product-type.application";
  };
  A00000000000000000000005 = {
   isa = PBXNativeTarget;
   buildConfigurationList = A00000000000000000000012;
   buildPhases = (A00000000000000000000021);
   buildRules = (); dependencies = ();
   fileSystemSynchronizedGroups = (A00000000000000000000007);
   name = OrbitTests; productName = OrbitTests;
   productReference = A00000000000000000000009;
   productType = "com.apple.product-type.bundle.unit-test";
  };
  A00000000000000000000006 = { isa = PBXFileSystemSynchronizedRootGroup; path = Sources/Orbit; sourceTree = "<group>"; };
  A00000000000000000000007 = { isa = PBXFileSystemSynchronizedRootGroup; path = Tests/OrbitTests; sourceTree = "<group>"; };
  A00000000000000000000008 = { isa = PBXFileReference; explicitFileType = wrapper.application; path = Orbit.app; sourceTree = BUILT_PRODUCTS_DIR; };
  A00000000000000000000009 = { isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = OrbitTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
  A00000000000000000000010 = { isa = XCConfigurationList; buildConfigurations = (A00000000000000000000030); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
  A00000000000000000000011 = { isa = XCConfigurationList; buildConfigurations = (A00000000000000000000031); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
  A00000000000000000000012 = { isa = XCConfigurationList; buildConfigurations = (A00000000000000000000032); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
  A00000000000000000000020 = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
  A00000000000000000000021 = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
  A00000000000000000000030 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
   SWIFT_VERSION = 6.0;
   SWIFT_STRICT_CONCURRENCY = complete;
   MACOSX_DEPLOYMENT_TARGET = 14.0;
   SDKROOT = macosx;
   CLANG_ENABLE_MODULES = YES;
   SWIFT_OPTIMIZATION_LEVEL = "-Onone";
   ENABLE_TESTABILITY = YES;
   CODE_SIGNING_ALLOWED = NO;
  }; };
  A00000000000000000000031 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
   PRODUCT_NAME = "$(TARGET_NAME)";
   PRODUCT_BUNDLE_IDENTIFIER = org.example.Orbit;
   GENERATE_INFOPLIST_FILE = YES;
  }; };
  A00000000000000000000032 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
   PRODUCT_NAME = "$(TARGET_NAME)";
   PRODUCT_BUNDLE_IDENTIFIER = org.example.OrbitTests;
   GENERATE_INFOPLIST_FILE = YES;
   LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@loader_path/../Frameworks", "@executable_path/../Frameworks");
  }; };
 };
 rootObject = A00000000000000000000001;
}
''')
    write(root, 'Orbit.xcodeproj/xcshareddata/xcschemes/Orbit.xcscheme', '''<Scheme version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000004" BuildableName="Orbit.app" BlueprintName="Orbit" ReferencedContainer="container:Orbit.xcodeproj"/>
</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000005" BuildableName="OrbitTests.xctest" BlueprintName="OrbitTests" ReferencedContainer="container:Orbit.xcodeproj"/>
</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
<Testables><TestableReference skipped="NO">
<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000005" BuildableName="OrbitTests.xctest" BlueprintName="OrbitTests" ReferencedContainer="container:Orbit.xcodeproj"/>
</TestableReference></Testables></TestAction>
</Scheme>
''')
    write(root, 'Sources/Orbit/OrbitApp.swift', '''import SwiftUI
@main struct OrbitApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
''')
    write(root, 'Sources/Orbit/ContentView.swift', '''import SwiftUI
struct ContentView: View { var body: some View { Text("Welcome") } }
#Preview { ContentView() }
''')
    write(root, 'Tests/OrbitTests/OrbitTests.swift', '''import XCTest
final class OrbitTests: XCTestCase { func testExample() { XCTAssertTrue(true) } }
''')
    write(root, '.swiftlint.yml', 'included:\n  - Sources\nonly_rules:\n  - trailing_whitespace\n')
    write(root, '.xcode-version', '16.0\n')
    write(root, 'Resources/Localizable.xcstrings', '{"sourceLanguage":"en","strings":{},"version":"1.0"}\n')
    write(root, 'README.md', '''# Orbit
Small macOS SwiftUI application with a standalone XCTest target.
Requires Xcode 16 or newer for synchronized source folders. Read Sources/Orbit for view examples.
Info.plist and entitlements changes require an explicit feature request because they change app capabilities.
''')
    write(root, 'Makefile', '''build:
\txcodebuild -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -derivedDataPath .build/xcode build
test:
\txcodebuild -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -derivedDataPath .build/xcode test
test-one:
\txcodebuild -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -derivedDataPath .build/xcode -only-testing:OrbitTests/OrbitTests/testExample test
lint:
\tswiftlint lint --strict
''')


def fixtures(base):
    base.mkdir(parents=True, exist_ok=True)
    roots = {name: base / name for name in ['swiftui', 'swiftpm', 'monorepo', 'existing', 'no-xcode']}
    for root in roots.values():
        root.mkdir()
    xcode_fixture(roots['swiftui'])
    package_fixture(roots['swiftpm'])
    mono = roots['monorepo']
    package_fixture(mono / 'Modules/MathKit')
    xcode_fixture(mono / 'Apps/Orbit')
    write(mono, 'Apps/Orbit/project.yml', '''name: Orbit
options:
  deploymentTarget:
    macOS: '14.0'
settings:
  base:
    SWIFT_VERSION: '6.0'
    SWIFT_STRICT_CONCURRENCY: complete
    CODE_SIGNING_ALLOWED: NO
targets:
  Orbit:
    type: application
    platform: macOS
    sources: [Sources/Orbit]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: org.example.Orbit
  OrbitTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/OrbitTests]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: org.example.OrbitTests
schemes:
  Orbit:
    build:
      targets:
        Orbit: all
        OrbitTests: [test]
    test:
      targets: [OrbitTests]
''')
    write(mono, 'Makefile', '''generate:
\tcd Apps/Orbit && xcodegen generate --spec project.yml
test-core:
\tcd Modules/MathKit && swift test
''')
    write(mono, 'README.md', '''# Workspace
Orbit is generated from Apps/Orbit/project.yml. Run `make generate` after changing that spec.
Do not edit its pbxproj directly: regeneration overwrites manual edits.
MathKit is a standalone package. Run `make test-core` from the repository root.
''')
    existing = roots['existing']
    package_fixture(existing)
    write(existing, 'AGENTS.md', '''# Maintainer notes

## Release ritual — authored by Mira

Do not rename public symbols during documentation updates: downstream tools depend on them.
Keep the release checklist exactly as written in this section.

## Tests

Run `swift test` from the repository root.
''')
    write(existing, 'Sources/AGENTS.md', '# Sources\nPreserve public API names for downstream compatibility.\n')
    xcode_fixture(roots['no-xcode'])
    return roots


def snapshot(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file() and not p.is_symlink()}


class Scenarios(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='swift-agents-scenarios-')
        cls.roots = fixtures(Path(cls.temp.name) / 'fixtures')
        cls.bin = Path(cls.temp.name) / 'bin'
        cls.bin.mkdir()
        for name, body in {
            'swift': 'import json,sys\nprint("Swift version 6.0 (test stub)" if "--version" in sys.argv else json.dumps({"name":"MathKit","targets":[{"name":"MathKit"},{"name":"MathKitTests"}]}))\n',
            'xcodebuild': 'import json,sys\nprint("diagnostic on stderr", file=sys.stderr)\nprint("Xcode 16.0 (test stub)" if "-version" in sys.argv else json.dumps({"project":{"schemes":["Orbit"],"targets":["Orbit","OrbitTests"]}}))\n',
        }.items():
            path = write(cls.bin, name, f'#!{sys.executable}\n{body}')
            path.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def report(self, name, probes=False, missing=False):
        root = self.roots[name]
        before = snapshot(root)
        with mock.patch.dict(os.environ, {'PATH': '' if missing else str(self.bin)}):
            result = discover.discover(root, probe_projects=probes, timeout=5)
        self.assertEqual(before, snapshot(root), 'Discovery changed repository files')
        self.assertFalse(result['verification']['build_and_test_commands_run'])
        return result

    def test_1_swiftui_xcode_swiftlint(self):
        result = self.report('swiftui', probes=True)
        self.assertEqual(result['inventory']['formatting_configs'], ['.swiftlint.yml'])
        self.assertEqual(result['schemes_from_xml'][0]['target_references'], ['Orbit', 'OrbitTests'])
        self.assertEqual(result['project_probes'][0]['status'], 'ok')
        self.assertEqual(result['project_probes'][0]['data']['project']['targets'], ['Orbit', 'OrbitTests'])
        self.assertIn('diagnostic on stderr', result['project_probes'][0]['error_output'])
        self.assertIn('Orbit', json.loads(result['project_probes'][0]['output'])['project']['schemes'])
        self.assertTrue(any('MACOSX_DEPLOYMENT_TARGET' in v['text'] for v in result['settings_evidence']))
        self.assertFalse((self.roots['swiftui'] / 'AGENTS.md').exists())

    def test_2_swiftpm_six_no_ui(self):
        result = self.report('swiftpm', probes=True)
        self.assertEqual(result['inventory']['swift_packages'], ['Package.swift'])
        self.assertEqual(result['inventory']['xcode_projects'], [])
        self.assertTrue(any('swiftLanguageModes: [.v6]' in v['text'] for v in result['settings_evidence']))
        self.assertEqual(json.loads(result['project_probes'][0]['output'])['name'], 'MathKit')
        self.assertEqual(len(result['sample_candidates']), 2)
        self.assertTrue(any('Tests/' in p for p in result['sample_candidates']))

    def test_3_xcodegen_monorepo(self):
        result = self.report('monorepo', probes=True)
        self.assertIn('Apps/Orbit/project.yml', result['inventory']['generator_files'])
        self.assertEqual(result['inventory']['swift_packages'], ['Modules/MathKit/Package.swift'])
        self.assertEqual(len(result['project_probes']), 2)
        package_probe = result['project_probes'][1]
        self.assertEqual(Path(package_probe['cwd']), (self.roots['monorepo'] / 'Modules/MathKit').resolve())
        for item in result['command_evidence']:
            source = self.roots['monorepo'] / item['path']
            self.assertEqual(source.read_text().splitlines()[item['line'] - 1].strip(), item['text'])

    def test_4_manual_document_preview_preserves_bytes(self):
        root = self.roots['existing']
        result = self.report('existing')
        self.assertIn('Sources/AGENTS.md', result['inventory']['documents'])
        before = snapshot(root)
        authored = (root / 'AGENTS.md').read_text()
        candidate = Path(self.temp.name) / 'AGENTS.candidate.md'
        candidate.write_text(authored + '\n## Build\n\nRun `swift build` — (не проверено): not run in this unit test.\n')
        errors, diff, digest, count = check_document.inspect(candidate, root)
        self.assertEqual(errors, [])
        self.assertIn('+Run `swift build`', diff)
        self.assertEqual(digest, hashlib.sha256((root / 'AGENTS.md').read_bytes()).hexdigest())
        self.assertLessEqual(count, 150)
        self.assertEqual(before, snapshot(root))
        # Invalid output must be rejected without modifying the original.
        for bad in ['line\n' * 151, '[missing](missing/file.swift)\n', '{{unfilled}}\n',
                    '[outside](../escape.md)\n']:
            candidate.write_text(bad)
            self.assertTrue(check_document.inspect(candidate, root)[0])
            self.assertEqual(before, snapshot(root))

    def test_5_no_xcode_no_swift(self):
        result = self.report('no-xcode', probes=True, missing=True)
        self.assertEqual(result['tools']['xcodebuild']['status'], 'missing')
        self.assertEqual(result['tools']['swift']['status'], 'missing')
        self.assertEqual(result['project_probes'][0]['status'], 'missing')
        self.assertTrue(any('xcodebuild' in v['text'] for v in result['command_evidence']))
        self.assertEqual(result['schemes_from_xml'][0]['name'], 'Orbit')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keep', type=Path, help='Also create fixtures in a new directory for manual evaluation')
    args = parser.parse_args()
    if args.keep:
        if args.keep.exists():
            parser.error('--keep directory must not exist')
        roots = fixtures(args.keep)
        print(json.dumps({key: str(value) for key, value in roots.items()}, ensure_ascii=False, indent=2))
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Scenarios))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
