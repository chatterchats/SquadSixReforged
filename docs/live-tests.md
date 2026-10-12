# In-game checks

Runs on a game copy (Instance 2, build 25134257) through ZC Sandbox, with Squad Six at acf2884 and
the dev probe installed. Missions are launched straight from the Den (`mission launch`), not from a
campaign, and the copy also runs other mods (OffDuty, QuickWin, Enhanced_Databank, BetterCamera,
ColorsPlus, Fast_Resonance, MixamooModConfigManager).

## Skirmishes: SK_Lothal_035_Crisis, SK_Lothal_050

Six operators, full flow works: destinations 4 → 6, overflow operators moved onto the lane spots,
all six on distinct spots at the end. The game's relocation strands one or two operators outside
the volume, and the 3.5 s watchdog snaps them back (visible). Lothal 035's derived spot 585/989 is
about 117 uu above the floor; the operator drops onto it.

## MM_04_030_RetakeLuunata, four against six (2026-10-11)

Squad Expansion's tests reported an operator in terrain, a broken arrival and a crash at the first
encounter transition with six. Same route both times: intro, walk to area 0, first encounter,
console, turbolift, lower level, second encounter. Squad: Tesh Hawks, Jacira Ako, Kabb Uppercut,
Luco Bronc (+ Neiya Sun, Imani Zash).

| Step | Four | Six |
|------|------|-----|
| Start | ok | Neiya Sun spawns at 159338/-576078/-18340 and won't path (ignores move orders; teleported to continue). Same spot the watchdog pulled an operator from in an earlier six run. |
| Area 0 deployment | ok | ok: 4 → 6, two staged operators moved onto the lane, `near=6` |
| First encounter | console activation (`CriticalInteract`) required, then a second wave | same |
| Turbolift bellhop | soft-lock: the droid's `Interactable.bAllowInteractions` stays False | same |
| Lower-level arrival | all together | all together |
| Area 3 deployment | ok | two operators sent to the world origin (`origin:lane`, 0/0/169), restored by the 5 s watchdog onto the derived spots, then ran to spots ~3,500 uu off; placed by hand |
| Crashes | none | none |

Six gets through, but roughly. Not guarded at four for now: the start and area 3 problems are
placement work, not a reason to cap the mission.

The bellhop soft-lock happens at both sizes, so it isn't squad size. Squad Six never touches
interactables. Every run so far used the sandbox's `kill foes` in the first encounter, so a run
fought normally is still needed. Ruled out: the Den launch (it also happens launched from the
mission board through squad select) and the first encounter's blocking volumes (still enabled at
the droid, but `DisableBlockingVolumes` doesn't help). The droid's `Interactable.bAllowInteractions`
is False; the native default is true. Bypass: call
`BP_TacticalObjective_PlayConversation_C_1:HandleStationActivityCompleted(BP_NarrativeStation_Mission_C_1)`
(both in `MM_04_030_RetakeLuunata_Gameplay`); objective 050 (move to the lift) activates next.
`SetStationDialogueEnabled(true)` and setting the flag directly don't help.

### Fixes (in `placement.lua`, covered by `tests/live_fixes_test.lua`)

- **Repairs at four operators.** In both four-operator deployments Squad Six ran `placement_repair`
  while the game was still walking the squad in, and moved one operator to the same spot twice for
  `shared_tile` (area 0: 145068/-576374; area 3: 120039/-578118). Now a squad no bigger than the
  area's authored destinations isn't repaired at all (`placement_repair=skipped
  reason=stock_squad`), and `shared_tile`, like `off_lane`, waits until the operator stops moving.
- **Area 3 after the watchdog.** The two restored operators walked off after `placement_final`: a
  teleport doesn't cancel the controller's path. Every rescue and repair teleport now calls
  `StopMovement` on the operator's controller (`halted=` in `placement_repair`), and drift checks
  10 and 20 s after the relocation log any restored operator more than 300 uu from where it was
  put (`placement_drift`, report only: they can't tell the game's walk from the player's).
- **Derived spot heights.** Area 3's derived spots were 105 and 155 uu above the floor (probe), as
  on Lothal 035. Derived points now go to the navmesh under them plus the squad's measured capsule
  height, where the navmesh answers (`floor_settled=` in `placement_rescue`, `derived_floor` for
  added destinations).
- **Neiya's spawn.** The spot (159338/-576078) projects to no navmesh at all, while the squad's
  start does. Until the first deployment of a mission with more than four operators, one standing
  still off the navmesh for 6 s, with half the squad on it and a squadmate within 2000 uu, is moved
  beside that squadmate (`spawn_rescue=moved`, `spawn_watch=done`).

### Six again, with the fixes (12ffd3a, 2026-10-11)

Self-check: startup 23/23, squad_select 2/2, mission 3/3.

| Step | Six |
|------|-----|
| Start | `spawn_rescue=moved from=159338/-576078/-18340 to=159275/-576293/-18219`, 18 s in; that operator then walked with the squad. `spawn_watch=done reason=deployment after=164s rescued=1` |
| Area 0 deployment | `floor_settled=2/2 largest_shift=-14`; no repair needed, all six distinct |
| Turbolift bellhop | same soft-lock; bypassed |
| Area 3 deployment | `floor_settled=2/2 largest_shift=-163`; nobody sent to the origin, no repair, no drift; the two operators on derived spots stand at the same height as their squadmates |
| Crashes | none |

The origin relocation didn't happen at all: the floating derived destinations seem to have been
what the game's relocation rejected. The bellhop needs a real campaign launch to check.

### Four again, with the fixes (12ffd3a, 2026-10-11)

Area 0: `placement_repair=skipped reason=stock_squad units=4 authored=4`, `repair_passes=0`, no
spawn watch activity; the game put all four on the four authored destinations. (Before: three
repair passes and one operator teleported twice.)

### Campaign saves (12ffd3a, 2026-10-12)

Loaded from the user's own campaign saves, no sandbox commands (`cmd.txt` untouched since the
day before), six operators. Mods synced from the main install (Off Duty 1.1.1 with fatigue off,
Fast Resonance rewrite, Skip Space Travel 1.0.0).

**The bellhop droid talks.** The soft-lock was the sandbox setup (`kill foes`, or the forked
sandbox campaign), not Squad Six or squad size.

| Mission | Result |
|---------|--------|
| MM_04_030_RetakeLuunata (twice) | start: the operator on the off-navmesh spawn (159338/-576078) moved, as before; area 0: `floor_settled=2/2`, one `outside_volume` restore in the first run (then drifted ~330 uu to an authored spot, as in the board run), none in the second. The second run was played to the end, all four encounters (below) |
| SK_Brentaal_035 | `spawn_rescue=moved` twice at 7 s (BR-1 from -2863/599, the custom operator from -3061/718: the two rearmost spawns), `on_navmesh=4` |
| MM_04_010_CoilStrikesBack | `spawn_rescue=moved` twice at 7 s (-12489/8185, -12573/8403), `on_navmesh=4`; the first one walked afterwards |
| SK_Mapuzo_020 | deployment: two operators moved onto the lane, one restored at rung2000, which the game's relocation then walked ~850 uu to another spot (`placement_drift`); all six distinct |
| SK_Vandor_020 | no spawn rescue |
| HM_Cly_010, HM_Luco_010 | four operators, nothing done |

Retake Luunata, the second run, played through:

| Encounter | Result |
|-----------|--------|
| 1 (area 0) | two operators moved onto the lane, `largest_shift=-4`; no restore |
| Bellhop | talks |
| 2 (lower level) | `floor_settled=2/2 largest_shift=-162`; no origin relocation, no restore, no drift |
| 3 | destinations 4 → 6 already on the floor (`largest_shift=0`); one operator on a squadmate's tile while staged, left to the game, which separated them; no moves |
| 4 (Z ~56600) | destinations 4 → 6, `largest_shift=-0`; operators off the lane while walking in, none restored; `placement_final near=6` |
| End | mission complete; the user saw everyone placed properly |

Self-check: startup 23/23, squad_select 2/2, mission 3/3. No crashes, no Squad Six errors.

The spawn watch acts on more maps than Retake: on Brentaal 035 and Coil Strikes Back two of six
operators started off the navmesh. Not yet checked whether they could have walked from there.

## MM_02_030_DarkGrotto ("Dark Waters"), six (211c41c, 2026-10-12)

From the user's campaign save, played through. Squad Expansion keeps this mission at four.
Probe 0.2.0 (the 0.1.0 probe made mission loads hitch; see its README).

The probe's spot checks, 11 s in:

| Area | Result |
|------|--------|
| `BP_CombatPreparationArea_C_1` | all four authored and both derived spots on the navmesh, floor within 50 uu |
| `BP_CombatPreparationArea_C_0` | authored spots on the navmesh; derived2 (-12146/-20189/3030) **not on the navmesh**, with something ~186 uu tall over it. The floor trace missed under most spots at 11 s and hit at 56 s, so collision there streams in late |

| Encounter | Result |
|-----------|--------|
| 1 (area C_0) | the two overflow operators (one ~290 uu above the others) moved onto derived1 and derived2; `floor_settled=1/2` (derived2 has no navmesh, so it kept its interpolated height). The game's relocation then walked that operator to -12193/-20236/3094, ~65 uu off and on the floor. All six distinct, nothing restored. The user saw two operators "spawn kinda off", then walk to their spots |
| 2 (area C_1) | overflow operators ~1,500 uu back and up to 560 uu higher moved onto the derived spots, `floor_settled=2/2`; nothing restored |
| End | mission complete, no errors |

**Gap, fixed since:** a derived point the navmesh doesn't cover was still used (at its interpolated
height). Here the game's relocation recovered; elsewhere it might send the operator to the origin,
as Retake's floating spots did. Derived points with no navmesh under them are now skipped for the
next candidate (`off_navmesh_skipped=`), covered by `tests/live_fixes_test.lua`.

Rerun with the fix (bdda677), encounter 1: `off_navmesh_skipped=4` (the spot under the prop and
three others), the overflow operators moved onto -12038/-19878 and -12083/-19995,
`floor_settled=2/2`, nothing restored. The relocation then walked the second one ~50 uu to
-12083/-19943, about 80 uu from the first (`shared_tile:already_staged`, left alone); in game they
stand close but on separate tiles. The probe's checks after the rescue said the occupied spots had
no navmesh nearby, against Squad Six's check just before: the navmesh appears to be cut around
standing units, so, like the floor trace, the probe's checks of occupied spots can't be trusted.

## MM_05_030_BellyBeast ("Unfinished Business"), six (bdda677, 2026-10-12)

From the user's campaign (reached normally). Squad Expansion keeps this mission at four.

The probe at 11 s: both areas flat; all authored and derived spots on the navmesh.

| Encounter | Result |
|-----------|--------|
| 1 (area C_0) | Tel Rea and Trick still standing at the start, ~1,300 uu back, while the rest walked: moved onto the derived spots, `floor_settled=2/2`. The relocation reshuffled (Trick to an authored spot, Luco onto the derived one Trick left). All six distinct, nothing restored |
| 2 (area C_1, ~62,000 uu away) | two overflow operators moved onto the derived spots, `floor_settled=2/2`. One operator was still ~58,000 uu back at the trigger (`outside_volume`): the watchdog put them on the lane at 3.5 s and 5 s, and both times they were back on their route 1.5 s later, further along; then `outside_volume:exhausted`. At 20 s they stood on an authored spot (the game placed them). The user saw nothing wrong |

The second area seems to be reached by something scripted that overrides teleports, and the game
places stragglers itself. Squad Six's two teleports there were wasted. If another map shows the
same, operators that far away (say more than 20,000 uu) could be left to the game.

## MM_06_090_FathomFinale ("The Infinite Coil"), six (bdda677, 2026-10-12)

From the user's sandbox campaign, reached through the story, played through. Squad Expansion keeps
this mission at four; arctco's notes record Harakiri's report of an operator in a crate on the
staircase in area C_1 (1.1.3 derived 13074/2050 at Z -200 and 12845/2050 at Z 0) and others
landing on a ledge or inside geometry. Self-check: startup 23/23, squad_select 2/2, mission 3/3.

The probe at 11 s: areas C_2, C_3 and C_4 flat, all authored and derived spots on the navmesh.
Area C_1 has two authored spots at Z 0 and two at Z -200 (the staircase); derived2 there,
12845/2050, has no navmesh under it.

| Step | Result |
|------|--------|
| Start | two operators off the navmesh moved beside squadmates at 8 s (`spawn_rescue=moved`, `on_navmesh=4`) |
| 1 (area C_1, stairs) | the crate spot 12845/2050 skipped (`off_navmesh_skipped=1`); the two overflow operators moved onto 13074/2050 and 13137/1880, settled from the interpolated Z -100 onto the lower floor (`floor_settled=2/2 largest_shift=-100`). Final: two at the top (Z 98), four at the bottom (Z -103), all distinct, nothing restored |
| 2 (area C_2) | arctco's profile for this area (`placement_rescue=FathomFinale`): two operators moved onto its points, at the squad's height; nothing restored, `near=6` |
| 3 (area C_3) | only two operators in at the trigger (`near=2`), the rest ~2,700 uu back. Two moved onto the derived spots (`floor_settled=2/2`). The watchdog then teleported stragglers four times (3.5, 5 and 7 s; added spot 1 was the target three times), but one kept coming back onto its route until `outside_volume:exhausted`, and the relocation reshuffled the others onto authored spots (`placement_drift`). The user saw all six placed properly |
| 4 (area C_4) | all six in at the trigger; two moved onto the derived spots, `floor_settled=2/2`, one candidate skipped for no navmesh; nothing restored |
| End | mission complete, no errors |

Nobody in a crate, in geometry, floating or under the floor.

**Follow-up:** area 3 repeats what Unfinished Business area C_1 showed, with a straggler only
~2,700 uu back instead of ~58,000, so a distance threshold wouldn't separate the cases. While the
game is still walking an operator in, a teleport doesn't hold (even with `StopMovement`), and the
game places them itself. Better: once an operator the watchdog teleported is found back on its
route, stop teleporting it and leave it to the game.

## Squad select (12ffd3a, 2026-10-11)

All six models show in the lineup: `proxies=6 valid_proxies=6 hidden_proxies=0`, layout applied
(the first pass found the stock four placed and two at the centre; the second spread all six at
fit 0.60), `slot_widgets=6 activity_slot_vms=6`. The squad_select self-check passed (2/2).
