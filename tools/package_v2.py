#!/usr/bin/env python3
"""Build the v1-runtime-retirement upgrade package from the cooked v2 plugin.

Compatibility is the default for 2.0.0: a single Scripts/main.lua stub replaces
v1 (confirmed in Zero Mod Manager); clean upgrades left the runtime installed. Use --clean for a diagnostic clean ZIP or
--both to produce both variants.

Keeps v1 Core filenames for mod-manager replacement detection. Internal /SquadSixGF/
asset paths remain stable to preserve the tested references.
Does not modify the live installation or the v1 source/release packager.
"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CORE = 'Content/Paks/~mods/SquadSixReforged_Core'
RUNTIME = 'Binaries/Win64/ue4ss/Mods/SquadSixReforged'
OLD_CONTAINER = 'pakchunk99-SquadSixReforged_P'
STUB = b'-- Squad Six Reforged v2 upgrade compatibility: retired v1 module.\n-- Gameplay now runs in the Game Feature pak; no hooks or timers are registered here.\nreturn {}\n'


def encoded(obj):
    return (json.dumps(obj, indent=2) + '\n').encode()


def manifest(version, runtime=False):
    return {
        'schemaVersion': 1,
        'id': 'community.squad-six-reforged' + ('' if runtime else '.core'),
        'name': 'Squad Six Reforged' if runtime else 'Squad Size Reforged - Core',
        'version': version,
        'author': 'Chats; original Squad Six by arctco',
        'description': ('Harmless replacement for the v1 Lua runtime. Gameplay is in the v2 pak.' if runtime
                        else 'Six-operator squads using a Game Feature plugin. UE4SS is not required.'),
        'game': {'appId': 2075800, 'testedBuilds': ['25134257', '25898267'], 'strict': True},
        'type': ['ue4ss'] if runtime else ['iostore'],
        'requires': {'ue4ss': False},
        'nexus': {'modId': 340},
    }


def info(m):
    return {k: m[v] for k, v in [('title', 'name'), ('version', 'version'), ('author', 'author'), ('description', 'description')]}


def instructions(compat):
    return '''Squad Six Reforged v2.0.0

Gameplay is pak-only and does not require UE4SS. The internal plugin path remains
SquadSixGF; that is intentional and does not affect the player-facing name. Keep all three container files.

UPGRADING FROM v1
1. Close the game. If upgrading from v1, keep it installed until replacement.
2. Remove the manually installed SquadSixGF_P.pak/.ucas/.utoc trial files from
   Content/Paks/~mods/ before installing this ZIP. Do not load both copies.
3. Import this ZIP, use the manager's Replace/Update option and deploy it.
4. Check that the old Core entry was replaced, not left alongside another pak.
5. Check the runtime folder at Binaries/Win64/ue4ss/Mods/SquadSixReforged/.
''' + ('''   For this compatibility ZIP, the runtime contains a harmless Scripts/main.lua
   stub plus zcom-mod.json and modinfo.json preserving its upgrade identity. Install BOTH components when offered. ZMM was confirmed to
   remove the old modules on replacement. Other managers may leave unused files.
''' if compat else '''   For this clean ZIP, that old runtime must be removed/disabled by the manager
   or manually before playing. This archive cannot request deletion by itself.
''') + '''6. Restart the game and check squad select, holotable range and deployment.
7. When uninstalling, use the manager that deployed the files.

MANUAL INSTALL
Archive paths start inside SWZeroCompany/. Extract into SWZeroCompany/, allowing
replacement of the old Core containers. Clean edition: remove the v1 UE4SS mod
folder. Compatibility edition: overwrite its Scripts/main.lua with the stub.
Do not change UE4SS itself, mods.txt, other mods or player settings.

EXPECTED LIMITS
Zero Mod Manager source detects replacement by matching container source names
and UE4SS folder names. Keeping these names offers each v1 component as an
upgrade candidate. Upgrade matching was tested in Zero Mod Manager and Mod Command.
Vortex upgrade cleanup has not been verified. Choose update or
replace rather than installing a second independent copy. File-conflict rules
must let v2 win. The compatibility ZIP does not erase files or disable an older
mod that a manager redeploys later. Its Lua stubs are optional upgrade aids,
not a dependency. No fake or empty Unreal containers are included.
'''


def build(version, compat, text_only=False, main_only=False):
    release = ROOT / 'release' / version
    committed = (release / 'build.json').is_file()
    source = release / 'paks' if committed else ROOT / 'dist/gf/own/SWZeroCompany/Content/Paks/~mods'
    if committed:
        record_data = json.loads((release / 'build.json').read_text())
        for relative, expected in record_data['inputs'].items():
            assert hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() == expected, f'Stale cooked input: {relative}'
        for name, expected in record_data['paks'].items():
            assert hashlib.sha256((source / name).read_bytes()).hexdigest() == expected, f'Changed cooked payload: {name}'
    hashes = {}
    files = {}
    for ext in ('pak', 'ucas', 'utoc'):
        p = source / f'SquadSixGF_P.{ext}'
        data = p.read_bytes()
        if not data:
            raise ValueError(f'Empty container: {p}')
        files[f'{CORE}/{OLD_CONTAINER}.{ext}'] = data
        hashes[p.name] = hashlib.sha256(data).hexdigest()
    # Refuse a partially copied/stale set: every payload must match build_gf.sh's record.
    if not committed:
        record = (ROOT / 'dist/gf/SHA256SUMS').read_text()
        for name, digest in hashes.items():
            assert f'{digest}  own/SWZeroCompany/Content/Paks/~mods/{name}' in record, name
    m = manifest(version)
    files[f'{CORE}/zcom-mod.json'] = encoded(m)
    files[f'{CORE}/modinfo.json'] = encoded(info(m))
    files[f'{CORE}/README-UPGRADE.txt'] = instructions(compat).encode()
    files[f'{CORE}/CREDITS.md'] = (ROOT / 'CREDITS.md').read_bytes()
    if compat:
        # Keep the original runtime identity for manager upgrade matching, with only
        # the entry-point stub as executable content.
        files[f'{RUNTIME}/Scripts/main.lua'] = STUB
        runtime_manifest = manifest(version, runtime=True)
        files[f'{RUNTIME}/zcom-mod.json'] = encoded(runtime_manifest)
        files[f'{RUNTIME}/modinfo.json'] = encoded(info(runtime_manifest))
    if text_only:
        files[f'{RUNTIME}/delete_me.txt'] = (
            'Upgrade experiment: this folder may be deleted after the v1 runtime is removed.\n'
            'This text file does not disable Lua files left behind by an overlay install.\n'
        ).encode()
        files[f'{CORE}/README-UPGRADE.txt'] = (
            'TEXT-ONLY UPGRADE EXPERIMENT — not the recommended compatibility package.\n'
            'Start from manager-installed v1.4.3, not the compatibility stubs.\n'
            'Check whether replacing with this ZIP REMOVES Scripts/main.lua and the old Lua modules.\n'
            'If old scripts remain, do not launch: uninstall v1 or install Compatibility instead.\n'
            'The only file provided in the runtime folder is delete_me.txt.\n'
            'Zero Mod Manager may not recognise it as a UE4SS component without main.lua.\n'
        ).encode()
    if main_only:
        files[f'{RUNTIME}/Scripts/main.lua'] = STUB
        files[f'{CORE}/README-UPGRADE.txt'] = (
            'MAIN-ONLY UPGRADE EXPERIMENT.\n'
            'The old UE4SS runtime folder contains only Scripts/main.lua in this archive.\n'
            'That entry point returns an empty table without loading any old modules.\n'
            'Start from manager-installed v1.4.3 and select Update/Replace.\n'
            'Check whether the manager removes other old files or leaves them unused.\n'
            'No runtime metadata, enabled.txt, MXM settings or delete_me.txt is shipped.\n'
        ).encode()
        assert [n for n in files if n.startswith(RUNTIME + '/')] == [f'{RUNTIME}/Scripts/main.lua']
    variant = 'MainOnly-Experiment' if main_only else 'TextOnly-Experiment' if text_only else 'Compatibility' if compat else 'Clean'
    name = f'SquadSixReforged-{version}.zip' if compat and '-' not in version else f'SquadSixReforged-{version}-{variant}.zip'
    target = ROOT / 'dist' / name
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(2026, 10, 19, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            z.writestr(entry, data)
    with zipfile.ZipFile(target) as z:
        assert z.testzip() is None
        assert {n: z.read(n) for n in z.namelist()} == files
        assert not any(n.endswith('/MXM/values.lua') or n.endswith('/mods.txt') for n in z.namelist())
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    target.with_suffix('.zip.sha256').write_text(f'{digest}  {target.name}\n')
    print(f'{target}: {len(files)} verified files; sha256={digest}')
    return target


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--version', default=json.loads((ROOT / 'release.json').read_text())['version'])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--clean', action='store_true', help='diagnostic pak-only package; does not retire v1 Lua')
    mode.add_argument('--main-only', action='store_true', help='runtime folder containing only stubbed Scripts/main.lua')
    mode.add_argument('--text-only', action='store_true', help='experimental runtime folder containing only delete_me.txt')
    mode.add_argument('--both', action='store_true', help='build both upgrade-test variants')
    args = ap.parse_args()
    if args.main_only:
        build(args.version, False, main_only=True)
    if args.text_only:
        build(args.version, False, text_only=True)
    if args.clean or args.both:
        build(args.version, False)
    if not args.clean and not args.text_only and not args.main_only:
        build(args.version, True)
