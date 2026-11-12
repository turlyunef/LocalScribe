#!/usr/bin/env python3
"""Measure only summary on a COPY of an existing synthetic technical-probe run."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import signal
import subprocess
import time
import uuid


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def measure(worker, folder, run, models, output, label):
    manifest = read(folder / 'manifest.json')
    command = dict(version=1, jobId=manifest['id'], runId=run.name, stage='summarizing',
                   recordingPath=str(folder), modelsPath=str(models), toolsPath=str(models.parent / 'tools'))
    started = time.monotonic()
    with (output / (label + '-events.jsonl')).open('w') as events:
        child = subprocess.Popen([str(worker)], stdin=subprocess.PIPE, stdout=events,
                                 stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        try:
            # Keep stdin open: EOF is the real worker's cancellation command.
            child.stdin.write(json.dumps(command) + '\n')
            child.stdin.flush()
            code = child.wait(timeout=1800)
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
    seconds = time.monotonic() - started
    metrics_path = run / 'metrics-summary.json'
    metrics = read(metrics_path) if metrics_path.exists() else None
    summary_path = run / 'summary.json'
    result = dict(label=label, seconds=seconds, exitCode=code, metrics=metrics,
                  summarySHA256=digest(summary_path) if summary_path.exists() else None)
    write(output / (label + '.json'), result)
    require(code == 0 and metrics and metrics['status'] == 'completed', 'Summary probe failed; see events and metrics')
    print(label, f'{seconds:.3f}s', 'requests:', sum(p['requests'] for p in metrics['phases'].values()), flush=True)
    return result


def main():
    repo = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-run', type=pathlib.Path, required=True)
    parser.add_argument('--worker', type=pathlib.Path, required=True)
    parser.add_argument('--metal-library', type=pathlib.Path, help='Defaults to the supplied worker\'s colocated or SwiftPM metallib')
    parser.add_argument('--models', type=pathlib.Path, default=repo / 'Assets/models')
    parser.add_argument('--output', type=pathlib.Path, default=repo / 'TestResults/summary-speed')
    parser.add_argument('--count', type=int, default=1)
    parser.add_argument('--check-resume', action='store_true')
    args = parser.parse_args()
    reference, worker, models = args.reference_run.resolve(), args.worker.resolve(), args.models.resolve()
    output = args.output.resolve()
    require(args.count > 0, '--count must be positive')
    require(output.is_relative_to(repo / 'TestResults'), 'Output must be inside this repository\'s TestResults')
    output.mkdir(parents=True, exist_ok=False)
    metal = args.metal_library or worker.parent / 'mlx.metallib'
    if not metal.exists():
        metal = worker.parent / 'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib'
    require(metal.is_file(), 'MLX metallib not found; supply --metal-library')
    helpers = output / 'helpers'
    helpers.mkdir()
    shutil.copy2(worker, helpers / 'LocalScribeWorker')
    shutil.copyfile(metal, helpers / 'mlx.metallib')
    worker = helpers / 'LocalScribeWorker'
    manifest, info = read(reference.parent.parent / 'manifest.json'), read(reference / 'run.json')
    require(manifest['sourceType'] == 'technical-probe', 'Only explicit synthetic technical-probe recordings are allowed')
    source = (reference.parent.parent / manifest['originalRelativePath']).resolve()
    require(source.is_relative_to(reference.parent.parent), 'Source must belong to the technical recording')
    require(manifest['sha256'] == info['sourceHash'] == digest(source), 'Source SHA mismatch')
    catalog_path = repo / 'Resources/models.lock.json'
    catalog = read(catalog_path)
    require(catalog.get('schemaVersion') == 1, 'Unsupported model catalog')
    profiles = []
    for role in ['asr', 'diarization', 'summary', 'tokenizer']:
        model_id = (info.get('modelIDs') or {}).get(role, role)
        matches = [m for m in catalog['models'] if m['id'] == model_id and m.get('role', m['id']) == role]
        require(len(matches) == 1, 'Pinned profile not found')
        profiles.append(matches[0])
    legacy = all(m['id'] == m.get('role', m['id']) for m in profiles)
    profile_text = ':'.join(m['revision'] if legacy else f"{m['id']}:{m['revision']}:" + ''.join(f['sha256'] for f in m['files']) for m in profiles)
    profile_hash = hashlib.sha256(profile_text.encode()).hexdigest()
    summary_model = profiles[2]
    for file in summary_model['files']:
        path = (models / summary_model['id'] / file['localPath']).resolve()
        require(path.is_relative_to(models / summary_model['id']), 'Invalid model file path')
        require(path.stat().st_size == file['size'] and digest(path) == file['sha256'], 'Summary model SHA/size mismatch')
    transcript = read(reference / 'transcript.json')
    fingerprint = hashlib.sha256((info['sourceHash'] + info['profileHash'] + info['pipelineVersion']).encode()).hexdigest()
    require(transcript['fingerprint'] == fingerprint and transcript['diarized'], 'Invalid reference transcript')
    # This is a NEW job, never a resume of the reference. Older smoke.py probes
    # hashed every catalog alternative; freeze only this job's four profiles.
    info['profileHash'] = profile_hash
    info['modelIDs'] = {role: profile['id'] for role, profile in zip(['asr', 'diarization', 'summary', 'tokenizer'], profiles)}
    reference_version = info['pipelineVersion']
    info['pipelineVersion'] = re.search(r'public var pipelineVersion = "([^"]+)"', (repo / 'Sources/LocalScribeCore/Contracts.swift').read_text()).group(1)
    transcript['fingerprint'] = hashlib.sha256((info['sourceHash'] + profile_hash + info['pipelineVersion']).encode()).hexdigest()
    write(output / 'environment.json', dict(platform=platform.platform(), workerSHA256=digest(worker), metalSHA256=digest(metal),
          catalogSHA256=digest(catalog_path), sourceSHA256=manifest['sha256'], transcriptSHA256=digest(reference / 'transcript.json'),
          modelID=summary_model['id'], modelRevision=summary_model['revision'], verifiedModelFiles=len(summary_model['files']),
          pipelineVersion=info['pipelineVersion'], referencePipelineVersion=reference_version, audioSeconds=manifest['durationMs'] / 1000))
    results = []
    for cycle in range(args.count):
        recording_id, run_id = str(uuid.uuid4()), str(uuid.uuid4())
        folder = output / recording_id
        run = folder / 'runs' / run_id
        run.mkdir(parents=True)
        copied_source = folder / manifest['originalRelativePath']
        copied_source.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, copied_source)
        require(digest(copied_source) == info['sourceHash'], 'Copied source SHA mismatch')
        now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
        write(folder / 'manifest.json', dict(manifest, id=recording_id, pendingRunId=run_id, activeRunId=None, createdAt=now))
        write(run / 'run.json', dict(info, id=run_id, createdAt=now, manualEdits=False))
        write(run / 'transcript.json', transcript)
        results.append(measure(worker, folder, run, models, output, f'fresh-{cycle}'))
        if args.check_resume:
            checkpoints = {p.name: digest(p) for p in (run / 'summary-parts').glob('*.json')}
            results.append(measure(worker, folder, run, models, output, f'resume-{cycle}'))
            require(checkpoints == {p.name: digest(p) for p in (run / 'summary-parts').glob('*.json')}, 'Resume changed valid checkpoints')
            require(results[-1]['summarySHA256'] == results[-2]['summarySHA256'], 'Resume changed the final summary')
        write(output / 'results.json', results)


if __name__ == '__main__':
    main()
