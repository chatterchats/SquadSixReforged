# Squad Six

[![Nexus Mods](https://img.shields.io/badge/Nexus%20Mods-original%20(mod%2044)-d98f40)](https://www.nexusmods.com/starwarszerocompany/mods/44)
[![UE4SS](https://img.shields.io/badge/framework-UE4SS-6f42c1)](https://github.com/UE4SS-RE/RE-UE4SS)

Squad Six raises the deployable squad size in **Star Wars: Zero Company** from four to six. It
combines an IoStore data override with a UE4SS Lua runtime that adds six activity slots, a
six-model lineup, a six-entry squad-selection layout and in-map placement for the extra operators.
Missions that inject scripted characters keep their authored limit of four.

> **Created by arctco.** This is a community continuation of arctco's discontinued mod,
> maintained with their permission. The manual testing and the hand-picked mission list are
> theirs; see [CREDITS.md](CREDITS.md).

## Status

Adopted from arctco's final release, **1.1.4** (2026-09-03), which is imported unmodified at tag
`upstream-1.1.4`. See [docs/upstream.md](docs/upstream.md) for what that release contains and
[docs/core-pak-analysis.md](docs/core-pak-analysis.md) for exactly what the cooked pak changes.

## Layout

```
src/Core/       cooked IoStore override + zcom-mod.json      -> Content/Paks/~mods
src/Runtime/    UE4SS mod ZCOMSquadSix + zcom-mod.json        -> ue4ss/Mods
  ZCOMSquadSix/Scripts/
    main.lua        loads the modules, registers hooks until every target exists, logs status
    limits.lua      mission squad limits at runtime, and the scripted-cast guards
    lineup.lua      squad selection: six slots, extra proxies, six-model lineup, nameplates
    placement.lua   tactical deployment: extra destinations, rescue, repair, squadsixrescue
    selfcheck.lua   logs whether every game name the other modules use still resolves
    common.lua      shared constants and reflection/vector helpers
data/           missions.tsv: the squad limit for every mission (what the Core pak changes)
                mapscan.json: every deployment area and its destination points (tools/map_scan.py)
docs/           upstream notes, file hashes, pak analysis, runtime-notes.md (why each rule exists)
tests/          runtime tests under a UE4SS stand-in (ue4ss_mock.lua): startup, self-check,
                lineup, rescue
tools/          build_core.py, inspect_core.py, package.py, run-tests.sh, and their helpers
```

`tools/run-tests.sh` runs the tests with LuaJIT. `bootstrap_test.lua ... --print` writes the
startup transcript instead, so two versions of the runtime can be diffed.

`src/` mirrors the release ZIP, which Zero Mod Manager installs as "Squad Six - Core" and
"Squad Six - Runtime". The mod IDs (`community.squad-six.core` / `.runtime`) and the UE4SS folder
name `ZCOMSquadSix` are kept, so existing installs upgrade in place.

## Building the Core pak

The pak is built from the installed game's own packages with
[retoc](https://github.com/trumank/retoc) 0.1.5; no editor or cook is needed. Edit
`data/missions.tsv`, then:

```sh
PAKS=".../SWZeroCompany/Content/Paks"
python3 tools/build_core.py --retoc /path/to/retoc --paks "$PAKS"           # writes src/Core
python3 tools/build_core.py --retoc /path/to/retoc --paks "$PAKS" --check   # compare only
python3 tools/inspect_core.py --retoc /path/to/retoc --paks "$PAKS"         # diff src/Core vs the game
```

After a game patch, run `--check` first: the build stops if the game's missions or their limits
changed, and lists what to review. See [docs/core-pak-analysis.md](docs/core-pak-analysis.md).

## After a game update

1. `python3 tools/build_core.py ... --check`: stops if the game's missions or squad limits changed.
2. Start the game and open squad select, then start a mission. In `UE4SS.log`, look for:
   ```
   [ZCOM_SQUAD_SIX] selfcheck phase=startup ok=22 missing=none unchecked=none
   [ZCOM_SQUAD_SIX] selfcheck phase=mission ok=3 missing=none unchecked=none
   ```
   `missing=` names each function, class or property that no longer exists (for example a
   Blueprint struct field whose GUID suffix changed). `unchecked=` means UE4SS couldn't inspect
   it, which says nothing either way.
3. `python3 tools/map_scan.py --retoc ... --paks "$PAKS"` re-reads every deployment area and its
   destination points into `data/mapscan.json`, and checks that each of `placement.lua`'s three
   hard-coded map layouts still matches exactly one area. Diff `data/mapscan.json` to see what a
   patch moved.

## Building a release

```sh
python3 tools/package.py            # dist/SquadSix-<version>.zip
python3 tools/package.py --verify   # also list which files differ from upstream 1.1.4
```

Bump `version` in both `zcom-mod.json` files and `VERSION` in `main.lua` together; the script
refuses to build if they disagree.

## Requirements

- Star Wars: Zero Company (tested build 24874058)
- UE4SS

## License

arctco gave permission to modify and continue the mod with credit, but chose no formal license.
Until they do, arctco keeps the rights to the original work, and copies must keep the credit in
[CREDITS.md](CREDITS.md).
