# Squad Six Reforged

[Get Squad Six Reforged on Nexus Mods](https://www.nexusmods.com/starwarszerocompany/mods/340)

**2.0.0** raises the deployable squad size in Star Wars: Zero Company to six using a Game Feature plugin. **UE4SS is no longer required.** It includes six squad slots, a six-model lineup with matching nameplates, the holotable's operator range, cover-aware deployment and hand-picked layouts for tricky encounters. Bespin remains solo; the opening tutorial keeps its authored squad. Not Your Turf, Dantooine 025 and Kaller 030 now allow six.

This continues **Squad Six by arctco**, with credit for the original mod, manual testing and hand-picked mission list. See [CREDITS.md](CREDITS.md).

## Install and upgrade

Install `SquadSixReforged-2.0.0.zip` with your mod manager, choosing **Update/Replace** for both existing components:

- **Squad Six Reforged**: a harmless `Scripts/main.lua` stub and the original runtime manifests. Install this component when upgrading so the previous Lua runtime stops running. It is not a UE4SS dependency for gameplay.
- **Squad Size Reforged - Core**: the v2 pak, ucas and utoc files. Keep all three together.

Upgrade matching was tested with Zero Mod Manager and Zero Company Mod Command. Vortex uses the existing combined Binaries/Content archive layout, but was not verified for v2.

For a manual install, close the game and extract the archive into `SWZeroCompany/`, replacing the old Core files and old runtime entry point. The pak lives in `Content/Paks/~mods/SquadSixReforged_Core/`; the stub lives in `Binaries/Win64/ue4ss/Mods/SquadSixReforged/Scripts/main.lua`. No UE4SS installation is needed for a new user. The other old Lua modules may remain after a manual overlay but the stub does not load them. Remove the old mod's MXM settings page if it remains visible. Do not remove UE4SS itself if other mods use it.

If you used the development trial, remove the separate `SquadSixGF_P.pak/.ucas/.utoc` files before installing the release. Do not deploy the same mod through two managers at once.

Build **25898267** is now allowed by the manifests, fixing the older strict-build installation block. The earlier gameplay tests were on build 25134257; the metadata update alone is not a new gameplay validation on 25898267.

## Behavior and limitations

The mod prefers free, walkable cover facing the encounter, then uses open ground when no suitable pocket is found. It does not create cover. Distant areas wait until the squad approaches before their destinations are prepared, allowing later encounter cover to stream in. A short mission-start pass separates overlapping operators where the game permits it.

V2 does not ship the old MXM settings interface or the `squadsixrescue` command. Its deployment repair is not a full port of the v1 watchdog. Keep other squad-size extensions disabled to avoid competing changes.

## Building

`python3 tools/package.py` builds the current release ZIP from checked-in cooked files under `release/2.0.0/`. The packager checks their hashes and the source inputs; it does not need Unreal Editor to assemble a release. `tools/package_v2.py` also offers experimental clean/main-only/text-only layouts for upgrade investigations; these are not the default release.

To author and cook, use `tools/build_gf.sh` with the SWZC Merged Kit. The build uses the frozen `data/placement.json` and `data/missions.tsv`; archived v1 Lua is not a build dependency. Internal asset paths remain `/SquadSixGF/` to preserve the tested references. The editor-only ZComAuthoring plugin is never shipped.

`src/`, the Lua tests and `tools/package_v1.py` retain the historical v1 implementation for reference. `unreal/specs/` contains the v2 Blueprint graph generators. See [CHANGELOG.md](CHANGELOG.md), [live tests](docs/live-tests.md) and [upgrade tests](docs/v2-upgrade-tests.md).
