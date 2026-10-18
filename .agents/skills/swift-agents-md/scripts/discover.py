#!/usr/bin/env python3
"""Collect bounded, attributed Swift repository evidence; never build or edit it."""

import argparse
import collections
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import xml.etree.ElementTree as ET


EXCLUDED = {'.git', '.build', '.swiftpm', 'DerivedData', 'Pods', 'Carthage',
            'node_modules', 'vendor', 'Vendor', 'build', 'dist', '__pycache__',
            '.agents', '.codex'}
MAX_TEXT = 256 * 1024
MAX_OUTPUT = 128 * 1024
SETTINGS = re.compile(
    r'swift-tools-version|swiftLanguage(?:Modes|Versions)|SWIFT_VERSION|'
    r'SWIFT_STRICT_CONCURRENCY|SWIFT_DEFAULT_ACTOR_ISOLATION|enableUpcomingFeature|'
    r'\.enableExperimentalFeature|StrictConcurrency|defaultIsolation|'
    r'DEPLOYMENT_TARGET|SDKROOT|SUPPORTED_PLATFORMS|platforms\s*:|'
    r'\.(?:iOS|macOS|watchOS|tvOS|visionOS|macCatalyst)\s*\(|'
    r'SWIFT_OBJC_BRIDGING_HEADER|PBXFileSystemSynchronized|PBXNativeTarget|'
    r'\.(?:target|testTarget|executableTarget|macro|plugin)\s*\(|'
    r'productName\s*=|name\s*[:=]|deploymentTarget|deploymentTargets|'
    r'swiftVersion|platform\s*:|strictConcurrency')
COMMANDS = re.compile(
    r'xcodebuild|swift\s+(?:build|test|package|format)|swiftlint|swiftformat|'
    r'xcbeautify|xcpretty|xcodegen|tuist|bazel|fastlane|bundle exec|'
    r'\b(?:scan|gym)\b|run_tests|build_app|make\s|just\s|scripts/')
SENSITIVE = re.compile(r'(?i)(?:secret|password|passwd|token|api[_-]?key|private[_-]?key)\s*[=:]')


def command(argv, cwd, timeout, max_output=MAX_OUTPUT):
    """Use argv, bounded output, a deadline, and process-group cleanup on POSIX."""
    result = {'argv': argv, 'cwd': str(cwd)}
    if shutil.which(argv[0]) is None:
        return dict(result, status='missing', reason=f'{argv[0]} not on PATH')
    try:
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(argv, cwd=cwd, stdout=output,
                                       stderr=errors,
                                       start_new_session=(os.name == 'posix'))
            try:
                code = process.wait(timeout=timeout)
                status = 'ok' if code == 0 else 'failed'
            except subprocess.TimeoutExpired:
                if os.name == 'posix':
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                code = process.wait()
                status = 'timeout'
            size = output.tell()
            output.seek(0)
            content = output.read(max_output).decode('utf-8', errors='replace')
            error_size = errors.tell()
            errors.seek(0)
            error_content = errors.read(max_output).decode('utf-8', errors='replace')
        return dict(result, status=status, exit_code=code, output=content,
                    output_truncated=size > max_output, error_output=error_content,
                    error_output_truncated=error_size > max_output)
    except OSError as error:
        return dict(result, status='error', reason=str(error))


def scan(root, warnings):
    listing = command(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                      root, 30, max_output=8 * 1024 * 1024)
    if listing['status'] == 'ok' and not listing['output_truncated']:
        files, directories = [], set()
        for rel in sorted(set(listing['output'].split('\0')) - {''}):
            path = root / rel
            if any(part in EXCLUDED for part in Path(rel).parts):
                continue
            if not path.is_file() or any(p.is_symlink() for p in [path, *path.parents] if p != root and p.is_relative_to(root)):
                continue
            files.append(rel)
            for parent in Path(rel).parents:
                if parent != Path('.'):
                    directories.add(parent.as_posix())
        return files, sorted(directories)
    if listing.get('output_truncated'):
        warnings.append('Git inventory exceeded 8 MiB; filesystem fallback may include ignored paths')
    files, directories = [], []
    def onerror(error):
        warnings.append(str(error))
    for base, dirs, names in os.walk(root, followlinks=False, onerror=onerror):
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDED
                         and not (Path(base) / d).is_symlink())
        for name in dirs:
            directories.append((Path(base) / name).relative_to(root).as_posix())
        for name in sorted(names):
            path = Path(base) / name
            if path.is_file() and not path.is_symlink():
                files.append(path.relative_to(root).as_posix())
    return sorted(files), sorted(directories)


def read(root, rel, warnings):
    try:
        with (root / rel).open('rb') as stream:
            data = stream.read(MAX_TEXT + 1)
        if len(data) > MAX_TEXT:
            warnings.append(f'{rel}: text truncated at {MAX_TEXT} bytes')
        return data[:MAX_TEXT].decode('utf-8', errors='replace')
    except OSError as error:
        warnings.append(f'{rel}: {error}')
        return ''


def evidence(root, paths, pattern, warnings, limit=500):
    found = []
    for rel in paths:
        for number, line in enumerate(read(root, rel, warnings).splitlines(), 1):
            if pattern.search(line):
                found.append({'path': rel, 'line': number,
                              'text': '[sensitive assignment omitted]' if SENSITIVE.search(line)
                              else line.strip()[:700]})
                if len(found) == limit:
                    warnings.append(f'evidence truncated at {limit} matches')
                    return found
    return found


def sample_sources(paths, limit=15):
    # Round-robin by parent module and test/production role, not the first 15 paths.
    groups = collections.defaultdict(list)
    for path in paths:
        if path.endswith('.generated.swift'):
            continue
        parts = Path(path).parts
        is_test = any('test' in part.lower() for part in parts)
        if parts[0] in ('Sources', 'Tests') and len(parts) > 2:
            module = parts[1]
        else:
            module = parts[0] if len(parts) > 1 else '.'
        groups[(is_test, module)].append(path)
    priority = re.compile(r'App\.|View\.|Model\.|Service\.|Client\.|Store\.|Test|Mock|Router|Coordinator')
    for group in groups.values():
        group.sort(key=lambda path: (not bool(priority.search(Path(path).name)), path))
    selected = []
    while len(selected) < limit and any(groups.values()):
        for key in sorted(groups):
            if groups[key] and len(selected) < limit:
                selected.append(groups[key].pop(0))
    return selected


def discover(root, static=False, probe_projects=False, timeout=30):
    root = Path(root).resolve()
    if not root.is_dir():
        raise ValueError(f'Not a directory: {root}')
    warnings = []
    files, directories = scan(root, warnings)
    named = lambda names: [p for p in files if Path(p).name in names]
    projects = [p for p in directories if p.endswith('.xcodeproj')]
    workspaces = [p for p in directories if p.endswith('.xcworkspace')
                  and not any(part.endswith('.xcodeproj') for part in Path(p).parts[:-1])]
    packages = named({'Package.swift'})
    generators = named({'project.yml', 'project.yaml', 'Project.swift', 'Tuist.swift', 'Workspace.swift'})
    dependency_files = named({'Podfile', 'Podfile.lock', 'Cartfile', 'Cartfile.resolved', 'Package.resolved'})
    bazel = named({'WORKSPACE', 'WORKSPACE.bazel', 'MODULE.bazel', 'BUILD', 'BUILD.bazel', '.bazelrc'})
    formatting = named({'.swiftlint.yml', '.swiftlint.yaml', '.swift-format', '.swiftformat'})
    version_files = named({'.xcode-version', '.swift-version', '.tool-versions', '.mise.toml', 'mise.toml'})
    documents = [p for p in files if Path(p).name in {'AGENTS.md', 'CLAUDE.md', '.cursorrules'}
                 or Path(p).name.upper().startswith(('README', 'CONTRIBUTING'))
                 or p.startswith('.cursor/rules/')]
    automation = [p for p in files if Path(p).name in {
        'Fastfile', 'Appfile', 'Gemfile', 'Gemfile.lock', 'Makefile', 'makefile', 'justfile',
        'Justfile', 'bitrise.yml', 'bitrise.yaml', '.gitlab-ci.yml', 'Jenkinsfile',
        'azure-pipelines.yml', '.travis.yml'} or p.startswith((
            '.github/workflows/', '.circleci/', '.buildkite/', 'ci/'))
        or 'scripts' in Path(p).parts or 'fastlane' in Path(p).parts]
    automation = [p for p in automation if Path(p).suffix.lower() not in {'.png', '.jpg', '.zip'}]
    settings_files = sorted(set(packages + generators + version_files
                               + [p for p in files if p.endswith(('.pbxproj', '.xcconfig'))]))
    settings = evidence(root, settings_files, SETTINGS, warnings)
    versions = {p: read(root, p, warnings).strip() for p in version_files}
    schemes = []
    for rel in files:
        if not rel.endswith('.xcscheme'):
            continue
        try:
            tree = ET.fromstring(read(root, rel, warnings))
            targets = sorted({node.attrib.get('BlueprintName', '')
                              for node in tree.iter('BuildableReference')})
            schemes.append({'path': rel, 'name': Path(rel).stem,
                            'shared': 'xcshareddata' in Path(rel).parts, 'target_references': targets})
        except ET.ParseError as error:
            warnings.append(f'{rel}: invalid scheme XML: {error}')
    source_paths = [p for p in files if p.endswith(('.swift', '.m', '.mm', '.h'))
                    and Path(p).name not in {'Package.swift', 'Project.swift', 'Tuist.swift', 'Workspace.swift'}]
    resources = [p for p in directories if p.endswith(('.xcassets', '.xcdatamodeld'))]
    resources += [p for p in files if p.endswith(('.xcstrings', '.entitlements', '.xcdatamodel'))
                  or Path(p).name in {'Info.plist', '.xccurrentversion', 'swiftgen.yml', 'swiftgen.yaml'}
                  or 'Bridging-Header' in p]
    tools = {}
    for name, argv in [('swift', ['swift', '--version']), ('xcodebuild', ['xcodebuild', '-version'])]:
        tools[name] = {'status': 'skipped', 'reason': '--static'} if static else command(argv, root, timeout)
    git = {name: command(argv, root, timeout) for name, argv in {
        'status': ['git', 'status', '--short'],
        'recent_commits': ['git', 'log', '-30', '--format=%h%x09%s'],
        'branches': ['git', 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes'],
        'current_branch': ['git', 'branch', '--show-current'],
    }.items()}
    tracked = command(['git', 'ls-files', '-z'], root, timeout)
    tracked_set = set(tracked.get('output', '').split('\0')) if tracked['status'] == 'ok' else set()
    tracking_complete = tracked['status'] == 'ok' and not tracked.get('output_truncated')
    lockfiles = [p for p in dependency_files if Path(p).name == 'Package.resolved']
    lock_tracking = {p: (p in tracked_set if tracking_complete else None) for p in lockfiles}
    probes = []
    if probe_projects and not static:
        for rel in workspaces + projects:
            option = '-workspace' if rel.endswith('.xcworkspace') else '-project'
            probes.append(command(['xcodebuild', '-list', '-json', option, rel,
                                   '-disableAutomaticPackageResolution'], root, timeout))
        for rel in packages:
            probes.append(command(['swift', 'package', 'dump-package'], (root / rel).parent, timeout))
        for probe in probes:
            if probe['status'] == 'ok' and not probe.get('output_truncated'):
                try:
                    probe['data'] = json.loads(probe['output'])
                except json.JSONDecodeError as error:
                    probe['parse_error'] = str(error)
    return {
        'schema_version': 1, 'root': str(root),
        'generated_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'excluded_directories': sorted(EXCLUDED),
        'inventory': {'xcode_projects': projects, 'xcode_workspaces': workspaces,
                      'swift_packages': packages, 'generator_files': generators,
                      'bazel_files': bazel, 'dependency_files': dependency_files,
                      'formatting_configs': formatting, 'automation': automation,
                      'documents': documents, 'resources': sorted(resources)},
        'configured_versions': versions, 'settings_evidence': settings,
        'schemes_from_xml': schemes,
        'command_evidence': evidence(root, sorted(set(automation + documents)), COMMANDS, warnings),
        'source_count': len(source_paths), 'sample_candidates': sample_sources(source_paths),
        'tools': tools, 'git': git, 'tracked_package_resolved': lock_tracking,
        'project_probes': probes,
        'verification': {'build_and_test_commands_run': False,
                         'note': 'Metadata only. CI commands and static settings are not verified builds.'},
        'warnings': warnings,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', default='.')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--static', action='store_true', help='Do not invoke Swift/Xcode; still inspect Git')
    mode.add_argument('--probe-projects', action='store_true', help='Execute xcodebuild -list and package manifests')
    parser.add_argument('--timeout', type=int, default=30, help='Per-command timeout in seconds')
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error('--timeout must be positive')
    try:
        report = discover(args.root, args.static, args.probe_projects, args.timeout)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
