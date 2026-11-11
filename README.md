# Squad Six Reforged

[Nexus Mods (340)](https://www.nexusmods.com/starwarszerocompany/mods/340) ·
[GitHub releases](https://github.com/chatterchats/SquadSixReforged/releases)

Raises the deployable squad size in Star Wars: Zero Company to six, as a Game Feature plugin: no
UE4SS needed. Six squad slots, a six-model lineup with matching nameplates, the holotable's
operator range, cover-aware deployment and hand-picked layouts for tricky encounters. A mission's
minimum squad is its required cast plus one. Bespin stays solo; the opening tutorial keeps its
authored squad. Player-facing text, with install and upgrade steps, is in [`docs/nexus/`](docs/nexus/).

This continues **Squad Six by arctco**, with credit for the original mod, manual testing and the
hand-picked mission list. arctco's work came without a licence, so there is no LICENSE file; see
[CREDITS.md](CREDITS.md).

## Commands

`make help` lists everything.

| Target | Does |
| --- | --- |
| `make test` | the Lua tests, under LuaJIT and again with only Lua 5.4's features (`tests/lua54.lua`) |
| `make build-gf` | cook the Game Feature with the SWZC Merged Kit (`tools/build_gf.sh`), then copy the paks into `src/` and record the cook in `unreal/build.json` |
| `make package` | `dist/SquadSixReforged-X.Y.Z.zip`; refuses paks that are stale against `unreal/build.json` |
| `make install` / `make uninstall` | link `src/SquadSixReforged_Core` into the main install's `Content/Paks/~mods` |
| `make bump V=X.Y.Z` | the version in `release.json`, both manifests, `README-UPGRADE.txt` and the `.uplugin` (`Version` and `VersionName`) |
| `make release` | check, test, tag, push; CI publishes to GitHub and Nexus |

A version bump changes the `.uplugin`, which is a cook input, so every release needs a
`make build-gf` after `make bump`: `make package` says so until it's done.

## Layout

The standard layout (`../ModTemplate/STANDARD.md`). Specific to this repo:

- `src/SquadSixReforged_Core/` is exactly what ships, at `Content/Paks/~mods/SquadSixReforged_Core/`:
  the cooked paks under v1's container name `pakchunk99-SquadSixReforged_P` (mod managers match
  upgrades on it), the two manifests and `README-UPGRADE.txt`. CREDITS.md is added when packaging.
  The paks are committed because cooking needs the Linux Unreal kit, which CI doesn't have.
- `unreal/SquadSixGF/` is the plugin project (internal paths stay `/SquadSixGF/` to keep tested
  references); `unreal/specs/` generates its Blueprint graphs; `unreal/scripts/` drives the kit.
  `unreal/build.json` hashes every cook input and pak.
- `tools/data/` holds the frozen inputs: `missions.tsv` (which missions go to six), `placement.json`
  (hand-picked layouts), `mapscan.json` (every deployment area), and the JSON schemas.
- `dev/v1/` is the retired v1 UE4SS runtime and its Core paks, kept for reference. The Lua tests
  and the v1 tools (`build_core.py`, `inspect_core.py`, `sandbox_check.py`,
  `encounter_directions.py`) work on it. `dev/SquadSixReforgedProbe` and
  `dev/SquadSixReforgedTestLimits` are in-game development probes.
- `tests/unreal/` holds kit-side tests run by `tools/test_*.sh`, not by `make test`.

## How it works

Behaviour, limits and the history of each fix are in [CHANGELOG.md](CHANGELOG.md),
[docs/live-tests.md](docs/live-tests.md), [docs/runtime-notes.md](docs/runtime-notes.md) and
[docs/placement-coverage.md](docs/placement-coverage.md). Upgrade testing across mod managers is
in [docs/v2-upgrade-tests.md](docs/v2-upgrade-tests.md); arctco's original release is described in
[docs/upstream.md](docs/upstream.md).

## Testing in game

After `make build-gf` and `make install`, restart the game and check squad select (six slots),
the holotable's operator range, and deployment on a mission with several encounters. Use a game
copy or a throwaway save: Squad Six changes the squad size of every campaign it loads in. Keep
other squad-size mods (such as Squad Expansion) out of the install.

Known gap: `tools/gf_sweep.py` loads `ZComDenDesigner/tools/dd.py`, which no longer exists, so the
all-missions sweep can't run until that helper is restored.
