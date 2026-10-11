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
data/           missions.tsv: the squad limit for every mission (what the Core pak changes)
docs/           upstream notes, file hashes, pak analysis
tools/          build_core.py, inspect_core.py, package.py, and their helpers
```

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
