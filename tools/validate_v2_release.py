"""Validate release payload, migration metadata and deterministic archive assembly."""
import hashlib
import json
import subprocess
import sys
import zipfile
from pathlib import Path

from package_v2 import ROOT, CORE, RUNTIME, STUB, build

version = json.loads((ROOT / 'release.json').read_text())['version']
first = build(version, True)
digest = hashlib.sha256(first.read_bytes()).hexdigest()
build(version, True)
assert hashlib.sha256(first.read_bytes()).hexdigest() == digest, 'Archive is not reproducible'
with zipfile.ZipFile(first) as z:
    assert z.testzip() is None
    runtime = {n for n in z.namelist() if n.startswith(RUNTIME + '/')}
    assert runtime == {f'{RUNTIME}/Scripts/main.lua', f'{RUNTIME}/modinfo.json', f'{RUNTIME}/zcom-mod.json'}
    assert z.read(f'{RUNTIME}/Scripts/main.lua') == STUB
    for folder, title, ident in [(RUNTIME, 'Squad Six Reforged', 'community.squad-six-reforged'),
                                 (CORE, 'Squad Size Reforged - Core', 'community.squad-six-reforged.core')]:
        m = json.loads(z.read(folder + '/zcom-mod.json'))
        assert m['version'] == version and m['name'] == title and m['id'] == ident
        assert m['requires']['ue4ss'] is False and '25898267' in m['game']['testedBuilds']
        info = json.loads(z.read(folder + '/modinfo.json'))
        assert info['title'] == title and info['version'] == version
    assert len([n for n in z.namelist() if n.endswith(('.pak', '.ucas', '.utoc'))]) == 3
    assert all(n.startswith(('Binaries/', 'Content/')) for n in z.namelist())
print('v2 release validation passed')
