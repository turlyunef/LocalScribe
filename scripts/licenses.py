#!/usr/bin/env python3
import argparse, pathlib, shutil
root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('dest', type=pathlib.Path)
dest = parser.parse_args().dest; dest.mkdir(parents=True, exist_ok=True)
origins = {}  # casefolded destination name -> source; collisions must not silently overwrite
def collect(source, name):
    key = name.casefold()
    if key in origins:
        raise SystemExit(f'licenses: name collision: {origins[key]} and {source} both map to {name}')
    origins[key] = source
    shutil.copyfile(source, dest/name)
for package in (root/'.build/checkouts').iterdir():
    if not package.is_dir(): continue
    for source in package.iterdir():
        if source.is_file() and source.name.lower().startswith(('license','copying','notice')):
            collect(source, package.name+'-'+source.name)
ff = root/'build/ffmpeg-licenses'
for name in ['COPYING.LGPLv2.1','COPYING.LGPLv3','LICENSE.md']:
    collect(ff/name, 'ffmpeg-'+name)
collect(root/'docs/ThirdParty.md', 'ThirdParty.md')
for name in ['LICENSE', 'NOTICES']:
    collect(root/'ThirdParty/SpeakerKit'/name, 'LocalScribeSpeakerKit-'+name)
for source in (root/'Resources/Licenses').glob('*'):
    if source.is_file(): collect(source, source.name)
