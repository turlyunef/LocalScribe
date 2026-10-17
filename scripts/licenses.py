#!/usr/bin/env python3
import pathlib, shutil, sys
root = pathlib.Path(__file__).resolve().parents[1]
dest = pathlib.Path(sys.argv[1]); dest.mkdir(parents=True, exist_ok=True)
for package in (root/'.build/checkouts').iterdir():
    if not package.is_dir(): continue
    for source in package.iterdir():
        if source.is_file() and source.name.lower().startswith(('license','copying','notice')):
            shutil.copyfile(source, dest/(package.name+'-'+source.name))
ff = root/'Vendor/ffmpeg-8.0.1'
for name in ['COPYING.LGPLv2.1','COPYING.LGPLv3','LICENSE.md']:
    if (ff/name).exists(): shutil.copyfile(ff/name, dest/('ffmpeg-'+name))
shutil.copyfile(root/'docs/ThirdParty.md', dest/'ThirdParty.md')
for source in (root/'Resources/Licenses').glob('*'):
    if source.is_file(): shutil.copyfile(source, dest/source.name)
