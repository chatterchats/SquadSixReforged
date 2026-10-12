# In-game checks

Runs on a game copy (Instance 2, build 24874058) through ZC Sandbox, with Squad Six at acf2884 and
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
interactables; likely the Den launch (the station spawns its NPC under
`Consequence.Characters.Bellhop`) or another mod. Bypass: call
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
