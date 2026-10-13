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

## MM_05_010_UmbaraRescue ("Deep Cover"), five (39370f2, 2026-10-12)

The first squad above four on a mission whose cast grows by script. The game authors it for three
(min 3, Hawks auto-assigned); Rex and the rescued clone Baker join through the mission. Raised to
five for the test with `dev/SquadSixReforgedTestLimits`, from the user's campaign save; Squad Six
Reforged 1.2.0 unchanged.

| Step | Result |
|------|--------|
| Limit | `squadsixlimit MM_05_010_UmbaraRescue 5` changed the definition (`set max 3 -> 5`), but squad select still built three slots: the galaxy map's `BrunoMissionViewModel` keeps its own `MaxSquadSize`, copied before the command. Reloading the save rebuilt it from the definition: five slots, five in the lineup |
| Slots | Squad Six's slot expansion ran on the five definitions (`slot_definitions=5->6`); its factory rebuild failed (`factory_rebuild=false`), so five stayed five. It assumes a four-slot list: **fix before any mission ships at five** |
| Start | 5 + Rex = 6 units, following properly. Two operators off the navmesh moved beside squadmates (`spawn_rescue=moved`, `on_navmesh=3`) |
| Encounter (the mission's only one) | game destinations 5 → 6 (`added_safe_points=1`), one operator moved onto the lane, `floor_settled=1/1`; the repair passes saw only units still walking (`:moving`), nothing restored, six distinct positions. The user saw all six spawn in, none clipped |
| Baker | rescued mid-encounter and joined the squad: seven units. Squad Six logged nothing, since it acts only at deployment |
| Save | a game save with seven units on the field finished normally (not loaded back: ZC Sandbox campaign) |
| End | mission complete, back to the Den, no errors |

So seven units alone doesn't hang a save; HM_Jae_020's hang at seven needs another explanation,
and each scripted-cast mission's cap has to be tested on its own. Deep Cover is authored for
3 + 2 joiners = 5 units, ran fine at 7.

Rerun at six (same save, `squadsixlimit ... 6`, then the save reloaded):

| Step | Result |
|------|--------|
| Start | six + Rex; three operators off the navmesh moved beside squadmates (`spawn_rescue=moved`, `on_navmesh=3`) |
| Encounter | seven units, five authored destinations, expansion capped at six (`player_destinations=5->6`, `destinations=6`): `WARNING: fewer destinations than deployed operators`, and two units walked to the same spot. The repair passes saw only units still walking |
| Spots | the user walked all seven onto spots they prefer; their positions, read through ZC Sandbox (`call <unit> K2_GetActorLocation`), became the `DeepCover` fixed layout (5d6551a) |
| Saves | game saves with seven units, and with eight after Baker joined, both finished |

Deep Cover now ships at six (missions.tsv), with the fixed spots.

Played with 399b368 installed (no test command): squad select offered six (`slot_widgets=6`).
At the encounter `fixed_spots=DeepCover destinations=5->7 written=7/7`, `destinations=7/7` for
seven units, and `placement_repair=skipped reason=fixed_spots` (`repair_passes=0`). Read through
ZC Sandbox once everyone had stopped, six units stood exactly on spots 1 and 3-7, and the seventh
55 uu from spot 2 on the same lower ground. The user saw them all walk onto the new spots. The
`mission ... unit_positions` line was logged while one was still walking (-828/-260).

## MM_04_050_ANewOrder ("Stillwatch"), six (9c690bd, 2026-10-12)

From the user's campaign, on the way to Rescue Jae Mordant. Six authored destinations (two named
for Trick and Tel-Rea); Trick joins through the mission, so seven units. `expanded=false`: the
expansion stops at six, so nothing was added, `WARNING: fewer destinations than deployed
operators`, and the sixth operator (Kara) stood in the open. The repair passes saw only units
walking. The user moved Kara to a spot they prefer; read through ZC Sandbox (2700/7847, the
floor of authored point 4), it became the seventh spot of the `Stillwatch` fixed layout.

## HM_Jae_020 ("Rescue Jae Mordant"), six (f52a6df + test build, 2026-10-12)

The mission arctco kept at four after a report that six became seven units and the save never
finished (five worked). Test build: HM_Jae_020 taken off `SCRIPTED_COMPANION_MISSION_NAMES` on
Instance 2 only, so the runtime raised it to six. From the user's campaign.

| Step | Result |
|------|--------|
| Start | six deployed: four authored destinations, two added (`player_destinations=4->6`), both overflow operators moved onto the lane, `floor_settled=2/2`; the repair passes saw only units walking |
| Jae | joined partway through, walking in from the side of the map: seven units (ZC Sandbox `units`), no duplicate |
| Saves | an autosave, then a manual save with seven units, both finished; the manual save loaded back fine |

Cover query, tried through ZC Sandbox at the deployed positions: `BrunoCoverGeneratorSubsystem.
GetCoverAtLocation` reported `LowCover` (facing -Y) at Kabb's spot and nothing at the others' exact
positions; `BRG_TargetingFunctionLibrary.GetNearestCoverForPoint` found cover 10 uu from Luco with
step-outs both sides (a flag combination, printed `(INVALID)` by the text export).

| End | the mission's only encounter; mission complete, back to the Den, no errors |

HM_Jae_020 now ships at six from the Core pak, off the guard list.

## MM_02_050_SlugHQ ("Smugglers' Den"), six (f318bfe + test build, 2026-10-12)

The mission arctco kept at four after a report of six becoming eight units with two Tal Reas.
Test build: `MM_02_050_SlugHQ` taken off the guard list on Instance 2 only. From the user's
campaign; squad Kabb, Hawks, Jae, Trick, Ravin (a custom character), BR-1.

| Step | Result |
|------|--------|
| Area 1 | cover found at deployment (`errors=0 unreadable=0`): 3 pockets, one used. The user saw one operator on the wrong side of cover; it was the one put into the "half cover facing the enemies", since the facing test had the normal backwards |
| Tel-Rea | joined before area 2 as the mission's own `Char_Hero_TelRea_Jedi_SlugHQ_C`: seven units, one Tel-Rea, standing on the mission's spot rather than a destination |
| Area 2 | 4 authored destinations; 2 added at the trigger (six units then) and a seventh when Tel-Rea joined (`destinations=7/7`). The user saw three on the wrong side of cover: the three the mod placed, in pockets with normal -X, against enemies to +X. The three on authored points (normal +X) were kept. Fixed in 9f42e43 |
| Spots | the user moved the mod's three into good spots; the authored four plus two of theirs became the `SmugglersDen2` fixed layout |
| Save | a manual save with seven units finished |
| End | mission complete, back to the Den, no errors |

Slug HQ now ships at six from the Core pak, off the guard list.

## Cover debug markers, SK_Serolonis_030 (19d2775, 2026-10-12)

`debug_cover_markers` on, `improve_game_spots` on. The game's four spots already had cover facing
the encounter (`improve_spots kept=4`). The staging search found 14 pockets: 3 usable, 4 crowded,
7 facing away; one operator went into full cover and one into half. The markers drew (`drawn
walls=5 tinted=1` on the first): the user saw green and yellow outlines on the crates, matching
3 usable and 4 crowded, and none on cover facing away.

Four crashes before that, all access violations at the first marker, fixed one step at a time
with the step trace (runtime-notes `COVER.markers`): the pocket written from Lua tables, the
class loaded and the marker spawned inside `TriggerPreCombat`, every wall in the marker's pool
tinted, and finally a bare string passed where `SetVectorParameterValue` takes an FName. With
the markers off, the same encounter never crashed.

## The Serolonis Job's tutorial and `improve_game_spots` (2026-10-13)

A player reported that a new campaign's tutorial couldn't go on with the mod installed:
Aurelio couldn't use his ability. Reproduced on Instance 2 from new campaigns and from the
encounter-start autosave of the second one. The stuck step is "Aurelio melee" in turn 2 of the
second fight (In The Box). The script sets up overwatch: one enemy walks into Hawks' cone and
dies, a second into Aurelio's and dies, then the game cancels Aurelio's overwatch and a third
enemy, a Separatist, sets up its own. Hawks flanks and shoots it, and Aurelio is meant to finish it in melee.

| Run | `improve_game_spots` | Probe, test limits, dev markers | Result |
|---|---|---|---|
| New campaign | on (`moves=-678/1052->-660/1150half` in that fight) | on | stuck at the melee |
| New campaign | off | on | stuck at the melee |
| Autosave, Squad Six off (twice) | n/a | off | third enemy survives the shot; melee works |
| Autosave, Squad Six on | off | off | melee works |
| Autosave, Squad Six on (twice) | on | off | stuck: Aurelio's overwatch isn't cancelled in time, so the third enemy takes a hit and dies to Hawks' shot, or doesn't move and set up |
| Autosave, 1.3.1 fix | on | on | melee works (`improve_spots=skipped reason=scripted_map`) |

So the setting caused the reported failure. Fixed by `COVER.scripted_maps`: the setting leaves
the Serolonis Job alone. The dev tools don't break the tutorial: with the fix, the setting on and
all of them on, the melee works. The second new-campaign failure is unexplained. Nothing in its log
shows the setting was really off, because `COVER.improve` returns without logging when it is.

## Hero missions at six (7043c6b + test build, 2026-10-13)

The test build lets seven hero missions take six (`COMPANION_AT_SIX_MISSION_NAMES` in limits.lua,
and the Core pak; see data/missions.tsv). The first install raised them at runtime only, and Best
Served Cold's squad select still offered four: it copies the limit when the galaxy map is built,
before the runtime's re-sweep. With the missions in the Core pak, startup logs
`data_container=loaded fallback_writes=0`. From the user's sandbox campaign on Instance 2.

| Mission | Squad select | Deployment | Save | Mission complete |
|---------|--------------|------------|------|------------------|
| HM_Cly_010 "Best Served Cold" | six after `squadsixlimit HM_Cly_010 6` (runtime-only build) | every operator in cover, after the fixes below | manual save finished | yes, back to the Den |
| HM_TelRea_010 "Origin of Infection" | six | good, after the direction fix | manual save finished and loaded | yes, back to the Den |
| HM_Luco_010 "Lord of Betrayal" | six | good | manual save finished | yes, back to the Den (user) |
| HM_Jae_010 "Distress Call" | six | hand-picked layout: everyone on its spots | manual save finished | yes, back to the Den |
| HM_Kabb_010 "Buy Cheap, Never Sleep" | six | one added operator in the open; cover up to two tiles out, not yet replayed | manual save finished | yes, back to the Den |

Best Served Cold: the deployment lane is at the end of a large tactical volume. The cover direction
(the volume's centre) was 34 degrees; all seven enemies (Idra Farr and six Pykes, read through ZC
Sandbox) stood at about 190. The two added spots went to adjacent half cover by the wall with the
enemies behind, and two of the game's spots moved the same wrong way. That led to
`tools/encounter_directions.py` and `directions.lua` (runtime-notes.md, "Which way the encounter
is").

Origin of Infection, three runs:
1. `math.atan2` in the new direction log line: UE4SS runs Lua 5.4, which has none, so the
   placement pass stopped (`destinations=4/4`); six walked onto four spots, Hawks into a piece of
   cover and Kabb in the open. Fixed; tools/run-tests.sh now also runs the tests without what
   Lua 5.4 lacks (tests/lua54.lua).
2. Directions from spawner positions: 215 degrees. A reinforcement spawner (Enemy1.4) stands in the
   lane; the six live Coil enemies stood at about 86 (the volume said 91). 14 of 16 cover pockets
   counted as facing away, and Luco and Cly got the lane's far edge.
3. Directions from spawn destinations: 82 degrees, `improve_spots kept=4 moved=0`, the added two
   in full and half cover (`chosen_full=1 chosen_half=1`). The probe: `enemies ... n=6 degrees=71`
   at their spawn. The user: "much better spawning positions".

Best Served Cold after the fix: direction 178 degrees, the probe's enemies at 181. Of 15 cover
pockets near the lane 10 faced away and 4 were within a tile of a spot or squadmate, so one added
operator got half cover and the other a derived point in the open (-3199/-5464). The user: "kind of
out of position, but there isn't really anywhere to go"; they suggested allowing cover up to two
tiles from the area instead of one. They also saw why: Cly stood on the game spot -3200/-4900, on
the seam between two half-cover tiles, so both were within a tile of her spot and refused as
crowded; centred on one, the other would have been Trick's. The improvement now snaps such a spot
onto its cover (`RESCUE.cover_snap`).

Replayed with the snap: Cly's spot moved onto its tile (`-3200/-4900->-3190/-4955half@snap`, and
`-3650/-6200->-3690/-6194half@snap`), but Trick still stood in the open. Sweeping the cover search
through ZC Sandbox on a 100 uu grid at two heights found 65 pockets; facing the enemies, the tile
beside Cly's (-3190/-4849, 106 uu from her spot, 52 past the lane's edge) was usable but never
returned by the mod's searches, the upper level's two were a game spot and the added half cover, and
the rest were 550-750 uu forward. The choice now also searches beside each pocket along its cover.

The first replay with that changed nothing: the spot's own tile was never found (a pocket facing
sideways was nearer every search centre), and the searches beside pockets were made 100 uu above
the floor with a 60 uu range, which finds nothing. With the search from each destination and at
floor height: 19 pockets, `usable=2 chosen_half=2`, Cly's tile listed as crowded
(`crowded_at=...,-3190/-4955<spot@-3190/-4955`). The second added operator took the tile beside the
other snapped spot (-3690/-6294); the one beside Cly's was among the two refused as outside, the
snapped spot having moved that corner of the lane. The user: "Every unit's behind cover!"

Distress Call (HM_Jae_010): direction 249 degrees, enemies at 229. All 14 pockets either faced
away (6) or were crowded (8), and both added operators stood in the open (-703/-2366,
-739/-2204). The crowded ones were the tiles along a barrier (-550, -450, -350, -250 at Y -2078)
beside game spots standing 5-10 uu off their own tiles (-540/-2065, -255/-2065): the free
neighbours were 91 and 96 uu from them, under the 100 uu the check used. Cover now counts as a
destination's own tile within 75 uu (`RESCUE.same_tile`).

Replayed: both added operators went into those tiles (-450/-2078, -902/-2340), and then the repair
(`via=watch5000 ... shared_tile:lane,shared_tile:lane`) moved the operators on the neighbouring game
spots, 91 and 98 uu away, to derived points in the open (-739/-2204, -703/-2366): it still took
under a whole tile for one tile. It now uses `RESCUE.same_tile` too. The user finds the area
cramped and suggested a hand-picked layout: they placed all six in game, read through ZC Sandbox
(operators stand 50.7 uu above destinations here), and the `DistressCall` fixed layout keeps two
authored points and adds four: -901.955/-2340 (the barrier's cover), 250/-2028.157,
-350/-1640 and -1448.258/-1920 on raised ground. Played with it: `fixed_spots=DistressCall
destinations=4->6 added=4 written=6/6`, `placement_repair=skipped reason=fixed_spots`, all six on
their spots; a manual save finished and the mission completed back to the Den.

Buy Cheap, Never Sleep (HM_Kabb_010): six on the squad screen; direction 205 degrees, enemies at
222. Two game spots snapped onto their cover; one added operator in half cover (6063/-3362), the
other on a derived point in the open (6083/-2823): 8 pockets, 3 facing away, 3 holding game spots,
1 outside, 1 usable. The user moved Kabb to 6015/-2500 (read with `squadsixprobe`; ZC Sandbox
refuses commands outside its sandbox campaign), the tile beside a snapped spot that the overlay
showed red: about a tile past the lane's edge. Added points may now take cover up to two tiles out
(`RESCUE.cover_outside`). A manual save finished.

Lord of Betrayal: no spawn destinations in its level, so the volume's centre, 351 degrees; the
probe found the eight enemies at 2. The added two in half cover; the game's four kept.
