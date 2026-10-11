# Upstream 1.1.4: what was adopted

Source: `Squad Six - ZCOM Mod Manager 44 1.1.4 2026-09-03T13-01Z KMDmZThtu.zip`, arctco's Zero Mod
Manager release (ZIP SHA256 `7abfdb1629030f5fdcbb32db620945d14d14ec150b74fbd2813ebe7209f1820e`).
The per-file hashes are in [`upstream-1.1.4.sha256`](upstream-1.1.4.sha256), and
`python3 tools/package.py --verify` reports which files have changed since then.

## The two halves

| Part | Files | Has source here? |
|------|-------|------------------|
| **Runtime** (UE4SS) | `src/Runtime/ZCOMSquadSix/Scripts/main.lua` (about 3,600 lines) | Yes. The Lua is the source. |
| **Core** (IoStore) | `src/Core/pakchunk99-ZCOMSquadSix_P.{pak,ucas,utoc}` | **No.** These are cooked binaries. |

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

- **The cooked overrides have no build script yet.** They can be regenerated from the game's own
  packages with retoc (see the analysis), but that tool isn't written yet.
- **The game build is pinned.** Both manifests list `testedBuilds: ["24874058"]` with
  `"strict": true`, so a game patch may need re-patched overrides and a manifest bump. Run
  `tools/inspect_core.py` after each patch.
- **There's no history before 1.1.4.** Only the comments in `main.lua` record earlier versions.
