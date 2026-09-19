"""Fetch the pinned official Sparkle artifact into the ignored build directory."""
import hashlib, json, pathlib, shutil, subprocess, tempfile, urllib.request
root = pathlib.Path(__file__).resolve().parent.parent
spec = json.loads((root / 'macos/Dependencies/Sparkle.json').read_text())
base = root / 'macos/.build/dependencies'
base.mkdir(parents=True, exist_ok=True)
destination = base / 'Sparkle.xcframework'
marker = base / 'sparkle.sha256'
tools = base / 'sparkle-bin'
if destination.exists() and all((tools / name).is_file() for name in ['generate_keys', 'generate_appcast', 'sign_update']) and marker.exists() and marker.read_text() == spec['sha256']:
    raise SystemExit(0)
with tempfile.TemporaryDirectory(dir=base) as temp:
    stage = pathlib.Path(temp)
    archive = stage / 'Sparkle.zip'
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(spec['url'], timeout=60) as response, archive.open('wb') as output:
        while data := response.read(1024 * 1024):
            size += len(data)
            if size > 100 * 1024 * 1024: raise RuntimeError('Sparkle archive exceeds size limit')
            digest.update(data); output.write(data)
    if digest.hexdigest() != spec['sha256']: raise RuntimeError('Sparkle checksum mismatch')
    subprocess.run(['ditto', '-x', '-k', str(archive), str(stage / 'unpacked')], check=True)
    candidates = list((stage / 'unpacked').rglob('Sparkle.xcframework'))
    if len(candidates) != 1: raise RuntimeError('Unexpected Sparkle archive layout')
    bins = list((stage / 'unpacked').rglob('bin/generate_appcast'))
    if len(bins) != 1: raise RuntimeError('Sparkle archive is missing update tools')
    if tools.exists(): shutil.rmtree(tools)
    shutil.move(str(bins[0].parent), tools)
    if destination.exists(): shutil.rmtree(destination)
    shutil.move(str(candidates[0]), destination)
    marker.write_text(spec['sha256'])
print('Verified Sparkle ' + spec['version'])
