# Upstream 1.1.4: what was adopted

Source: `Squad Six - ZCOM Mod Manager 44 1.1.4 2026-09-03T13-01Z KMDmZThtu.zip`, arctco's Zero Mod
Manager release (ZIP SHA256 `7abfdb1629030f5fdcbb32db620945d14d14ec150b74fbd2813ebe7209f1820e`).
The per-file hashes are in [`upstream-1.1.4.sha256`](upstream-1.1.4.sha256), and
`python3 tools/package.py --verify` reports which files have changed since then.

## The two halves

| Part | Files | Has source here? |
|------|-------|------------------|
| **Runtime** (UE4SS) | `src/Runtime/ZCOMSquadSix/Scripts/main.lua` (about 3,600 lines) | Yes. The Lua is the source. |
| **Core** (IoStore) | `src/Core/pakchunk99-ZCOMSquadSix_P.{pak,ucas,utoc}` | Cooked binaries; now built from `data/missions.tsv` by `tools/build_core.py`. |

The runtime builds the six activity-slot view models, the six-model lineup diorama, the six-entry
squad-select layout, and the placement of operators 5 and 6 inside each map's authored deployment
area. It also guards missions that inject scripted characters. The mission lists, the measurements
behind them and the bug reports that led to them are documented in the comments in `main.lua`.

## What the Core pak overrides

The pak has 106 cooked assets ([`pak-contents-1.1.4.txt`](pak-contents-1.1.4.txt)): 105 mission
definitions with `MaxSquadSize` raised from 4 to 6, and `AC_HologramManager` with its lineup loop
widened from four proxies to six. Each is the game's own package with one value changed. Details,
including the 20 missions left out and why: [`core-pak-analysis.md`](core-pak-analysis.md).

## Known gaps after adoption

- **The cooked overrides had no build script.** `tools/build_core.py` now rebuilds them from the
  game's own packages and reproduces all 106 of 1.1.4's packages byte for byte.
- **The game build is pinned.** Both manifests list `testedBuilds: ["24874058"]` with
  `"strict": true`, so a game patch may need re-patched overrides and a manifest bump. Run
  `tools/inspect_core.py` after each patch.
- **Release history:** arctco's notes for 1.1.0–1.1.4 are on their Nexus page, saved in
  [`upstream-nexus-page-1.1.4.md`](upstream-nexus-page-1.1.4.md). Earlier versions are only
  described in `main.lua`'s comments.
- **Only the Zero Mod Manager bundle was imported.** arctco also shipped a Manual archive with
  `ZCOMSquadSix/enabled.txt` (loads the mod without a `mods.txt` edit) and checksum-guarded
  `install.sh`/`uninstall.sh` for Linux. Those files aren't in this repository.
