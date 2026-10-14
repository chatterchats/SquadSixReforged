# Squad Six Reforged

[![Nexus Mods](https://img.shields.io/badge/Nexus%20Mods-Squad%20Six%20Reforged-d98f40)](https://www.nexusmods.com/starwarszerocompany/mods/340)
[![Original: Squad Six by arctco](https://img.shields.io/badge/Nexus%20Mods-original%20Squad%20Six%20(mod%2044)-d98f40)](https://www.nexusmods.com/starwarszerocompany/mods/44)
[![UE4SS](https://img.shields.io/badge/framework-UE4SS-6f42c1)](https://github.com/UE4SS-RE/RE-UE4SS)

Squad Six Reforged raises the deployable squad size in **Star Wars: Zero Company** from four to
six. It combines an IoStore data override with a UE4SS Lua runtime that adds six activity slots, a
six-model lineup, a six-entry squad-selection layout and in-map placement for the extra operators.
Extra operators deploy in cover facing the enemies where the area has some, the enemies' direction
coming from where each fight places them (`Scripts/directions.lua`, generated from the levels), and
a few maps have hand-picked deployment spots. Every hero mission takes six; only the opening
tutorial, whose squad the game sets, keeps four.

> **A continuation of Squad Six by arctco.** arctco created Squad Six, discontinued it, and gave
> permission for others to continue it with credit. Most of the runtime is still their code, and
> the manual testing and the hand-picked mission list are theirs; see [CREDITS.md](CREDITS.md).
> No licence has been chosen yet.

## Status

**1.4.1** (2026-10-14): works alongside ZC Unlocked with its squad code switched off. **1.4.0**
(2026-10-14): six operators in every hero mission, cover that faces where each fight
places its enemies, and better use of the cover beside the game's spots; see
[CHANGELOG.md](CHANGELOG.md). **1.3.0** (2026-10-13) added cover-aware deployment and a settings
page. **1.2.0** (2026-10-12) was the first release of Squad Six Reforged.
It continues from arctco's final release of Squad Six, **1.1.4** (2026-09-03), which is imported unmodified at tag
`upstream-1.1.4`. See [docs/upstream.md](docs/upstream.md) for what that release contains and
[docs/core-pak-analysis.md](docs/core-pak-analysis.md) for exactly what the cooked pak changes.

## Layout

```
src/SquadSixReforged/        the UE4SS mod ("Squad Six Reforged")  -> ue4ss/Mods/SquadSixReforged
  README.md       the player guide (ships in the mod folder; its title carries the version)
  enabled.txt     loads the mod on a manual install without a mods.txt edit
  modinfo.json, zcom-mod.json   Zero Company Mod Command and Zero Mod Manager manifests
  MXM/settings.lua   the Mixamoo Mod Config Manager settings page (optional for players)
  Scripts/
    main.lua        loads the modules, registers hooks until every target exists, logs status
    limits.lua      mission squad limits at runtime, and the scripted-cast guards
    lineup.lua      squad selection: six slots, extra proxies, six-model lineup, nameplates
    placement.lua   tactical deployment: extra destinations, rescue, repair, squadsixrescue
    selfcheck.lua   logs whether every game name the other modules use still resolves
    directions.lua  generated: which way each deployment area's enemies are (tools/encounter_directions.py)
    common.lua      shared constants and reflection/vector helpers
    MXM.lua         the Mixamoo Mod Config Manager client library, unmodified
src/SquadSixReforged_Core/   the cooked IoStore override ("Squad Six Reforged - Core") + its manifests
                                                          -> Content/Paks/~mods/SquadSixReforged_Core
data/           missions.tsv: the squad limit for every mission (what the Core pak changes)
                mapscan.json: every deployment area and its destination points (tools/map_scan.py)
dev/            never shipped: SquadSixReforgedProbe (in-game checks of placement spots and staging,
                and where the enemies are once combat is prepared;
                `squadsixprobe` also logs squad positions), SquadSixReforgedTestLimits
                (`squadsixlimit <mission> <n>` sets one mission's limit for a test), and
                mxm/debug_settings.lua (the cover debug-marker toggle, added on game copies only)
docs/           upstream notes, file hashes, pak analysis, runtime-notes.md (why each rule exists),
                placement-coverage.md (how placement does on every map)
tests/          runtime tests under a UE4SS stand-in (ue4ss_mock.lua): startup, self-check,
                lineup, rescue, probe, cover (cover choice, the game-spot improvement, debug markers),
                placement_maps (placement.lua over every deployment area in data/mapscan.json,
                including the fixed layouts)
tools/          build_core.py, inspect_core.py, map_scan.py, encounter_directions.py, sandbox_check.py, package.py,
                bump_version.py, nexus_changelog.py, run-tests.sh, and their helpers
.github/workflows/release-nexus.yml   manual Nexus release
```

`tools/run-tests.sh` runs the tests with LuaJIT. `bootstrap_test.lua ... --print` writes the
startup transcript instead, so two versions of the runtime can be diffed.

The release ZIP mirrors the game's `SWZeroCompany` folder (see Releasing), and Zero Mod Manager
and Zero Company Mod Command install it as "Squad Six Reforged" and "Squad Six Reforged - Core".
Its IDs (`community.squad-six-reforged` and `.core`), UE4SS folder (`SquadSixReforged`) and pak
(`pakchunk99-SquadSixReforged_P`) are its own, so it never installs over arctco's Squad Six
(`community.squad-six.*`, `ZCOMSquadSix`); the runtime warns at load if both are installed.

## Building the Core pak

The pak is built from the installed game's own packages with
[retoc](https://github.com/trumank/retoc) 0.1.5; no editor or cook is needed. Edit
`data/missions.tsv`, then:

```sh
PAKS=".../SWZeroCompany/Content/Paks"
python3 tools/build_core.py --retoc /path/to/retoc --paks "$PAKS"           # writes src/SquadSixReforged_Core
python3 tools/build_core.py --retoc /path/to/retoc --paks "$PAKS" --check   # compare only
python3 tools/inspect_core.py --retoc /path/to/retoc --paks "$PAKS"         # diff the pak vs the game
```

After a game patch, run `--check` first: the build stops if the game's missions or their limits
changed, and lists what to review. See [docs/core-pak-analysis.md](docs/core-pak-analysis.md).

## After a game update

1. `python3 tools/build_core.py ... --check`: stops if the game's missions or squad limits changed.
2. Start the game and open squad select, then start a mission. In `UE4SS.log`, look for:
   ```
   [SQUAD_SIX_REFORGED] selfcheck phase=startup ok=23 missing=none unchecked=none
   [SQUAD_SIX_REFORGED] selfcheck phase=squad_select ok=2 missing=none unchecked=none
   [SQUAD_SIX_REFORGED] selfcheck phase=mission ok=3 missing=none unchecked=none
   ```
   `missing=` names each function, class or property that no longer exists (for example a
   Blueprint struct field whose GUID suffix changed). `unchecked=` means UE4SS couldn't inspect
   it, which says nothing either way.
3. `python3 tools/map_scan.py --retoc ... --paks "$PAKS"` re-reads every deployment area and its
   destination points into `data/mapscan.json`, and checks that each of `placement.lua`'s three
   hard-coded map layouts still matches exactly one area. Diff `data/mapscan.json` to see what a
   patch moved.
4. `python3 tools/encounter_directions.py --retoc ... --paks "$PAKS"` re-reads every area's enemy
   spawners into `Scripts/directions.lua`, the direction cover faces. Both tools take
   `--cache DIR` to keep the extracted levels between runs.

## Checking in the game

`tools/sandbox_check.py` drives ZC Sandbox on a game copy (`Instance N`, as Off Duty's simtest uses).
It launches missions with a six-operator squad, lets the dev probe check the placement spots and
record the staging, can end encounters (`:advance=N`) to reach later deployments, and writes a
report to `dist/sandbox/`:

```sh
python3 tools/sandbox_check.py install --instance 2       # with that copy closed
python3 tools/sandbox_check.py info --instance 2          # with it running: roster and mission names
python3 tools/sandbox_check.py check --instance 2 --squad "A,B,C,D,E,F" \
    --missions SK_Lothal_035_Crisis,MM_01_010_SerolonisJob,MM_04_030_RetakeLuunata:advance=2
python3 tools/sandbox_check.py uninstall --instance 2     # closed again; probe output is kept
```

It never starts or stops the game, refuses to install while the copy runs, and stops at a crash.

## Releasing

The manually run **Release to Nexus Mods** workflow publishes a release; use `tools/package.py`
for a local, package-only build.

1. If `data/missions.tsv` changed, rebuild the pak with `tools/build_core.py` and commit
   `src/SquadSixReforged_Core` and `data/core-build.sha256`.
2. Add player-facing notes under `## [Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md), grouped as
   Added / Changed / Fixed / Removed.
3. Bump the version with `patch`, `minor` or `major`:

   ```sh
   python3 tools/bump_version.py minor
   ```

   It updates both components' `modinfo.json` and `zcom-mod.json`, `Scripts/main.lua` and the
   player README title, and turns `[Unreleased]` into the new version.
4. Run `tools/run-tests.sh` and `python3 tools/package.py` (`--verify` also lists which files
   differ from upstream 1.1.4), then check `dist/SquadSixReforged-#.#.#.zip` with the mod managers
   (Vortex included) and a clean manual install. A built version is immutable: the packager
   refuses to overwrite a ZIP with different contents.
5. Commit (`chore(release): v#.#.#`), tag `v#.#.#`, and push.
6. Run **Release to Nexus Mods** from the **Actions** tab. It needs the `NEXUSMODS_API_KEY`
   repository secret, and the Nexus page's mod ID in `src/SquadSixReforged/zcom-mod.json` as
   `"nexus": {"modId": N}`. The first file on a new page has to be uploaded by hand: the
   workflow replaces the page's single active file.

The ZIP, `SquadSixReforged-#.#.#.zip`, mirrors the game's `SWZeroCompany` folder, so a manual install is
one extract and Vortex takes it as a combo mod:

```
Binaries/Win64/ue4ss/Mods/SquadSixReforged/     src/SquadSixReforged's player files, plus CREDITS.md
Content/Paks/~mods/SquadSixReforged_Core/       the paks and their manifests
```

The workflow checks that all four manifests, `main.lua` and the README title agree, reads that
version's notes from the changelog (as plain text, via `tools/nexus_changelog.py`), runs the
tests, packages, and uploads as a new version of the page's single active file.

## Requirements

- Star Wars: Zero Company (tested builds 25134257 and 24874058)
- UE4SS

## License

arctco gave permission to modify and continue the mod with credit, but chose no formal license.
Until they do, arctco keeps the rights to the original work, and copies must keep the credit in
[CREDITS.md](CREDITS.md).
