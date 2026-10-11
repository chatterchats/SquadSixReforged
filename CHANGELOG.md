# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Adopted from arctco, the original author, after they discontinued the mod. The runtime's code is
unchanged from 1.1.4, now split across modules. The Core container is now built from the game's own packages by
`tools/build_core.py`, from the squad limits in `data/missions.tsv`.

### Added

- A startup self-check. The log now says whether every game name the runtime depends on still
  resolves: `selfcheck phase=startup ...` once the squad-selection assets load, and
  `selfcheck phase=mission ...` in the first mission. After a game update, `missing=` lists
  exactly what was renamed or removed.

### Fixed

- `squadsixrescue` could leave an operator stranded. When placing two stuck operators on their
  squadmates failed because the engine accepted a teleport but put the operator somewhere else,
  the command undid the first move but left that operator wherever it landed. Both are now put
  back.

### Changed

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
- The runtime is split into `main.lua` (loading and hook registration), `limits.lua`,
  `lineup.lua`, `placement.lua` and `common.lua`. The code is moved unchanged; 1.1.4's single file
  had reached Lua's limit of 200 top-level locals, so any addition would have stopped it loading.

Not yet tested in game.

## [1.1.4] - 2026-09-03

arctco's final release, imported unmodified (git tag `upstream-1.1.4`). arctco's release notes for
1.1.0–1.1.4 are kept in [docs/upstream-nexus-page-1.1.4.md](docs/upstream-nexus-page-1.1.4.md).
