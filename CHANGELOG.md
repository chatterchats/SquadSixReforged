# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0]

The first release since the mod was adopted from arctco, the original author, who discontinued
it. The runtime is now split across modules, with the placement fixes below. The Core container
is now built from the game's own packages by `tools/build_core.py`, from the squad limits in
`data/missions.tsv`. Tested in game (build 25134257) at six on Retake Luunata, Dark Waters,
Unfinished Business, The Infinite Coil and several skirmishes; see `docs/live-tests.md`.

### Added

- `ZCOMSquadSix/enabled.txt`, so a manual install loads without editing `mods.txt` (arctco's
  manual archive had one; the mod-manager bundle didn't).
- A player guide (`README.md`) and the credits (`CREDITS.md`) in the mod folder, and
  `modinfo.json` manifests for Zero Company Mod Command beside each part.
- `tests/placement_maps_test.lua` runs the placement rules over all 89 deployment areas: on 84 the
  two overflow operators end up inside the lane even when staged outside it and then stranded by
  the relocation. See `docs/placement-coverage.md`.
- `tools/map_scan.py` reads every deployment area and its destination points straight from the
  game's levels into `data/mapscan.json`, and checks that `placement.lua`'s hard-coded map layouts
  each still match exactly one area. It reproduces arctco's published figures: 89 areas, a median
  lane span of 1,060 uu, 86 of 89 under 2,000 uu.
- A startup self-check. The log now says whether every game name the runtime depends on still
  resolves: `selfcheck phase=startup ...` once the squad-selection assets load, and
  `selfcheck phase=mission ...` in the first mission. After a game update, `missing=` lists
  exactly what was renamed or removed.

### Fixed

- Operators 5 and 6 could be left outside the deployment lane on narrow lanes, where the
  fallback found no room: SK_Lothal_035 and its crisis variant (no interior point at all), and
  SK_Lothal_050 and OM_Crisis_Guardian_A. The fallback now
  also tries points between pairs of authored destinations when the lane's edges can't hold
  everyone. Other maps are unchanged.
- Retake Luunata (MM_04_030) at six: one of the game's start spots for operators 5 and 6 has no
  navmesh, so the operator on it couldn't move. Until the first deployment, an operator standing
  still off the navmesh while the rest of the squad is on it is moved beside a squadmate (squads
  over four only). This also happens on Brentaal 035, Coil Strikes Back and The Infinite Coil.
- Retake Luunata at six: on the lower level the added spots were 105–155 uu above the floor, and
  the game's relocation sent two operators to the world origin. Added spots are now put on the
  navmesh under them.
- Operators put back by the repair then walked away: a teleport doesn't cancel the walk the game
  gave them. Every rescue and repair teleport now stops the operator's movement, and operators
  who drift more than 300 uu from where they were put are logged (`placement_drift`).
- A squad of four on an area with four destinations was still repaired while it walked in, and one
  operator teleported. A stock squad is now left to the game (`placement_repair=skipped
  reason=stock_squad`), and an operator crossing a squadmate's tile isn't moved until it stops.
- A derived spot with no navmesh under it was used anyway: in Dark Waters (MM_02_030) one sat
  under a prop, and the operator only reached the floor because the game walked them off it.
  Such spots are now skipped for the next candidate (`off_navmesh_skipped=` in the log), whenever
  the navmesh answers under the area's authored destinations.
- `squadsixrescue` could leave an operator stranded. When placing two stuck operators on their
  squadmates failed because the engine accepted a teleport but put the operator somewhere else,
  the command undid the first move but left that operator wherever it landed. Both are now put
  back.

### Changed

- The download now mirrors the game's `SWZeroCompany` folder: the mod goes to
  `Binaries/Win64/ue4ss/Mods/ZCOMSquadSix` and the squad-limit pak to
  `Content/Paks/~mods/ZCOMSquadSix_Core`. A manual install is one extract, and Vortex can install
  it. Zero Mod Manager and Zero Company Mod Command still show the two parts, Squad Six - Runtime
  and Squad Six - Core. If you installed 1.1.4 or earlier by hand, delete the old
  `pakchunk99-ZCOMSquadSix_P.pak`, `.ucas` and `.utoc` directly inside `Content/Paks/~mods`, or
  both copies will load.
- Tested on game build 25134257 as well as 24874058. The manifests list both and stay strict.
- The Serolonis Job (MM_01_010_SerolonisJob) keeps its authored four operators. It's the opening
  tutorial and the game sets its squad, so the player can't pick operators; 1.1.4 raised it to six
  anyway. It's out of the container and the runtime guards it by name.
- Rescue Jae Mordant (HM_Jae_020) is no longer raised to six by the container. 1.1.4 already kept
  it at four at runtime; the container now agrees, as 1.1.3 intended for every guarded mission.
- SK_Serolonis_020, SK_Vandor_015, Coil Reunion (MM_02_010_CoilReunion) and the main-story
  placeholder are now raised to six by the container. Before, only the runtime raised them, which
  depended on the mission being loaded when the runtime checked; these definitions do store a
  squad limit, but UAssetAPI couldn't read them. With them in the container, the runtime has
  nothing left to raise, so a correct install should log `data_container=loaded`.

- The runtime's squad-limit sweep reads only mission definitions (`BrunoMissionData`) instead of
  probing every DataAsset in the game, which threw and caught an error for each non-mission asset
  on every pass.
- Removed dead diagnostics from the runtime. The relocation and lineup post-hooks are no longer
  registered: UE4SS never calls post-hooks on Blueprint functions, so they never ran, and the
  `relocation_post=` field of `placement_final` always read `false`. The camera census (the
  `cameras source=` lines), kept to diagnose a camera bug fixed in 1.0.6, is gone. The `lineup`
  line drops `post_hook_id=`; its before-pass positions and scales are now formatted only when the
  line is logged.
- arctco's long comments, which recorded the player reports and measurements behind each rule,
  moved word for word to `docs/runtime-notes.md`; the code keeps a short summary of each. Code
  unchanged.
- The runtime is split into `main.lua` (loading and hook registration), `limits.lua`,
  `lineup.lua`, `placement.lua` and `common.lua`. The code is moved unchanged; 1.1.4's single file
  had reached Lua's limit of 200 top-level locals, so any addition would have stopped it loading.

## [1.1.4] - 2026-09-03

arctco's final release, imported unmodified (git tag `upstream-1.1.4`). arctco's release notes for
1.1.0–1.1.4 are kept in [docs/upstream-nexus-page-1.1.4.md](docs/upstream-nexus-page-1.1.4.md).
