"""Validate release payload, migration metadata and deterministic archive assembly."""
import hashlib
import json
import subprocess
import sys
import zipfile
from pathlib import Path

from package_v2 import ROOT, CORE, RUNTIME, STUB, build, ships_stub

version = json.loads((ROOT / 'release.json').read_text())['version']
assert json.loads((ROOT / 'unreal/SquadSixGF/SquadSixGF.uplugin').read_text())['VersionName'] == version
record = json.loads((ROOT / 'release' / version / 'build.json').read_text())
assert record['version'] == version
assert {str(p.relative_to(ROOT)) for p in (ROOT / 'unreal/specs').glob('gf*.py')} <= set(record['inputs']), 'Untracked cooked source input'
stub = ships_stub(version)
if not stub:
    # CI runs this before uploading, so a release can't go out still telling players to install the placeholder.
    for path in ('README.md', 'docs/nexus/description.bbcode'):
        text = (ROOT / path).read_text().lower()
        for phrase in ('stub', 'both components', 'harmless'):
            assert phrase not in text, f'{path} still describes the UE4SS placeholder ("{phrase}"), which {version} does not ship'
first = build(version, stub)
digest = hashlib.sha256(first.read_bytes()).hexdigest()
build(version, stub)
assert hashlib.sha256(first.read_bytes()).hexdigest() == digest, 'Archive is not reproducible'
with zipfile.ZipFile(first) as z:
    assert z.testzip() is None
    assert f'Squad Six Reforged v{version}' in z.read(f'{CORE}/README-UPGRADE.txt').decode()
    runtime = {n for n in z.namelist() if n.startswith(RUNTIME + '/')}
    components = [(CORE, 'Squad Size Reforged - Core', 'community.squad-six-reforged.core')]
    if stub:
        assert runtime == {f'{RUNTIME}/Scripts/main.lua', f'{RUNTIME}/modinfo.json', f'{RUNTIME}/zcom-mod.json'}
        assert z.read(f'{RUNTIME}/Scripts/main.lua') == STUB
        components.insert(0, (RUNTIME, 'Squad Six Reforged', 'community.squad-six-reforged'))
    else:
        assert not runtime, f'{version} must not ship the UE4SS placeholder'
    for folder, title, ident in components:
        m = json.loads(z.read(folder + '/zcom-mod.json'))
        assert m['version'] == version and m['name'] == title and m['id'] == ident
        assert m['requires']['ue4ss'] is False and '25898267' in m['game']['testedBuilds']
        info = json.loads(z.read(folder + '/modinfo.json'))
        assert info['title'] == title and info['version'] == version
    assert len([n for n in z.namelist() if n.endswith(('.pak', '.ucas', '.utoc'))]) == 3
    assert all(n.startswith(('Binaries/', 'Content/')) for n in z.namelist())
print('v2 release validation passed')
