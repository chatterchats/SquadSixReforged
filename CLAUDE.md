# SquadSixReforged

@docs/agent-rules.md

Read README.md first: what ships, how the Game Feature is cooked, and where v1 went.

## Rules for this repo

- What ships is `src/SquadSixReforged_Core/`. Never rename its `pakchunk99-SquadSixReforged_P.*`
  files or the folder: mod managers detect the upgrade from v1 by those names.
- The paks are cooked, not edited. Change the sources (`unreal/specs/`, `tools/data/`), then
  `make build-gf`. After `make bump`, cook again: the `.uplugin` version is a cook input.
- `README.md` and `docs/nexus/description.bbcode` must not describe the retired UE4SS
  placeholder; `make package` fails if they do.
- `dev/v1/` is retired v1 code, kept for reference and its tests. Don't ship or install it.
- Credit arctco for the original Squad Six in anything player-facing (CREDITS.md). There is no
  licence to grant; never add a LICENSE file.
- Never install it on the user's real campaign without asking: it changes every campaign's squad
  size. Don't run it alongside Squad Expansion.
