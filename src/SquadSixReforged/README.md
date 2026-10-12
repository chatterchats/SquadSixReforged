# Squad Six Reforged v1.2.0 — Six-Operator Squads for Star Wars: Zero Company

Squad Six Reforged raises the deployable squad size from four to six operators.

**It continues Squad Six by arctco**, who created the original, discontinued it and allowed others
to carry it on with credit. Most of the mod is still arctco's work, including the manual testing
and the hand-picked list of missions behind it. See `CREDITS.md` beside this file.

## What it does

- **Squad select holds six:** six slots, all six operators in the lineup, and six nameplates.
- **Missions take six** wherever the game can handle it.
- **The extra two are placed properly in missions.** The game only marks four spots in each
  deployment area. Squad Six Reforged adds two more inside the area, on the floor, and moves
  operators 5 and 6 there if the game leaves them stuck or outside it.
- It doesn't change classes, progression, abilities, equipment, enemies or your saves.

## Missions that stay at four

These missions bring story characters in through their own scripting. Deploying six would
duplicate operators or stop the mission from saving, so they keep their usual four:

- The Serolonis Job (the opening tutorial; the game picks the squad)
- Smugglers' Den
- Buy Cheap, Never Sleep; Best Served Cold; Origin of Infection; Sisters; No Kings, No Masters;
  Rescue Jae Mordant
- Five more hero missions, by mission ID: HM_Cly_020, HM_Jae_010, HM_Kabb_020, HM_Luco_010 and
  HM_Trick_010 (their titles depend on the game's language)

## What you need

- Star Wars: Zero Company
- UE4SS for Star Wars Zero Company (Nexus Mods)
- No other squad-size mod, including arctco's original Squad Six or Squad Expansion: they change
  the same things. The log warns if one is installed alongside.

## Switching from arctco's Squad Six

Squad Six Reforged is a separate mod, so mod managers won't replace the original for you. Remove
Squad Six first: in your mod manager, or by hand, delete the **ZCOMSquadSix** folder in
`ue4ss/Mods` and the `pakchunk99-ZCOMSquadSix_P.pak`, `.ucas` and `.utoc` files in
`Content/Paks/~mods`. Neither mod stores anything in your saves, so your campaigns carry over.

## Installing

The download has two parts, and both are needed:

- **SquadSixReforged**: the mod itself (Squad Six Reforged).
- **SquadSixReforged_Core**: the mission squad limits (Squad Six Reforged - Core).

### With a mod manager

Install the downloaded ZIP with **Zero Mod Manager**, **Zero Company Mod Command** or
**Vortex**, install both parts, and make sure they're switched on.

### By hand

1. Close the game.
2. Extract the ZIP into the game's `SWZeroCompany` folder (the one holding `Binaries` and
   `Content`), merging folders. This puts **SquadSixReforged** in `Binaries/Win64/ue4ss/Mods/`
   and **SquadSixReforged_Core** in `Content/Paks/~mods/`.
3. Start the game.

## Updating

Close the game, then install the new version the same way. Restart the game after installing or
updating rather than using UE4SS's "Reload All Mods".

## Uninstalling

Switch both parts off or remove them in your mod manager, or delete the **SquadSixReforged**
folder in `ue4ss/Mods` and the **SquadSixReforged_Core** folder in `Content/Paks/~mods`. Finish
or abandon any mission in progress first: a mission saved with six operators expects the mod.

## If an operator gets stuck

If operators 5 or 6 end up somewhere they can't move from at the start of an encounter, open the
UE4SS console and enter `squadsixrescue`. It moves stuck operators back into the deployment area.

## Found a problem?

Report the mission name, what happened and which other mods you use, and attach `UE4SS.log`
(in `Binaries/Win64/ue4ss`). This mod's lines start with `[SQUAD_SIX_REFORGED]`. After a game
update, its `selfcheck` lines list anything the mod can no longer find (`missing=`). The log
may mention folder paths on your PC, so feel free to look it over before sending.
