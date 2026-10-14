# Squad Six Reforged v1.4.1 — Six-Operator Squads for Star Wars: Zero Company

Squad Six Reforged raises the deployable squad size from four to six operators.

**It continues Squad Six by arctco**, who created the original, discontinued it and allowed others
to carry it on with credit. Most of the mod is still arctco's work, including the manual testing
and the hand-picked list of missions behind it. See `CREDITS.md` beside this file.

## What it does

- **Squad select holds six:** six slots, all six operators in the lineup, and six nameplates.
- **Missions take six** wherever the game can handle it.
- **The extra two are placed properly in missions.** The game only marks four spots in each
  deployment area. Squad Six Reforged adds two more inside the area, on the floor, and moves
  operators 5 and 6 there if the game leaves them stuck or outside it. Story characters who join
  at the start of a mission get a spot too.
- **Spots in cover.** The added spots go into cover facing the enemies where the area has some,
  full cover first. The mod knows which way the enemies are from where each fight places them.
  By default the game's own spots move into such cover too when theirs faces away, or centre on
  the cover tile they stand in (see Settings). Cover up to two tiles past the deployment area's
  edge can be used.
- It doesn't change classes, progression, abilities, equipment, enemies or your saves.

## Which missions take six

Every mission that normally takes four takes six, including every hero mission, with one
exception:

- **The Serolonis Job** (the opening tutorial) keeps four: the game picks that squad.

Solo and three-operator missions keep their own limits, except Deep Cover, which takes six.

In hero missions, the characters the mission assigns (Hawks and the hero; Hawks, Trick and Luco in
No Kings, No Masters) fill their slots as usual, and you pick the rest. Characters a mission
brings in itself still come, so you can have more than six on the field: Rex in Deep Cover and No
Kings, No Masters, Baker in Deep Cover, Sergeant Sawtooth in No Clone Left Behind, Jae in You
Can't Go Home Again, Tel-Rea in Smugglers' Den and Trick in Stillwatch. Each of these missions was
played through at six, including saving.

## What you need

- Star Wars: Zero Company
- UE4SS for Star Wars Zero Company (Nexus Mods)
- No other squad-size mod, including arctco's original Squad Six or Squad Expansion: they change
  the same things. The log warns if one is installed alongside.
- **ZC Unlocked** works alongside with its own squad extension switched off: turn the Squad row
  off in ZC Unlocked Menu (`squad=0` in its `dlls/settings.ini`) and restart. The log warns while
  it's on. ZC Unlocked still hides the fifth and sixth models on the squad screen, so they flash
  briefly when the menu updates as Squad Six Reforged shows them again, and the mission board may
  say "4 operators" (add `squad_limit_text=0` under `[Squad]` to fix that); six still deploy.
- Optional: [Mixamoo Mod Config Manager](https://www.nexusmods.com/starwarszerocompany/mods/149),
  for the settings page

## Settings

With the [Mixamoo Mod Config Manager](https://www.nexusmods.com/starwarszerocompany/mods/149)
installed, Squad Six Reforged has an in-game settings page:

- **Move the game's spots into cover** (on by default): at the start of an encounter, a
  deployment spot whose cover faces away from the enemies, or that has none, moves to cover
  facing them within two tiles, and one standing off the centre of its cover tile moves onto it.
  It applies to every squad size except in the opening tutorial, from the next encounter. Turn it
  off to keep the game's own spots.

Without the settings manager, the defaults apply.

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
