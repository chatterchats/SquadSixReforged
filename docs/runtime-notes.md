# Runtime notes

arctco's design notes for the Squad Six runtime, moved out of the code. Up to 1.1.4 the runtime
was a single `main.lua` whose comments recorded, rule by rule, the player reports, log lines and
measurements each rule came from. They are kept here word for word, under the function or
constant they describe; the code keeps a short summary of each.

Version numbers, file names and line references in the notes are as arctco wrote them, so
"this file" means 1.1.4's `main.lua`. Players named here reported the bugs; see
[CREDITS.md](../CREDITS.md).

## main.lua

### `report_status`

One line that answers "is Squad Six actually running, and is it complete?"
Support triage reads this from UE4SS.log; nothing else in the log is needed.

Reported twice: once as soon as the data limits are known, so a log pasted
before the mission screen is opened still proves the mod is running, and
again when every hook is up. 1.0.4 reported only the early line, and
VM_ActivitySlotList does not exist until the mission screen opens, so that
line permanently recorded slot_hook=false on healthy installs. Every 1.0.4
report carries that false negative in the one line meant to settle whether
the install is sound.

## limits.lua: mission squad limits

### `LIMIT_ATTEMPT_CAP`

apply_data_limits sweeps every DataAsset in the process and only latches
once it has read more than ten. Until it latches the maintenance loop
re-runs that sweep every five seconds for as long as the game is open --
which means it can be enumerating UObjects during a level transition,
when the engine is tearing an array down and rebuilding it. A crash
report showed exactly that: an access violation inside UE4SS.dll reading
0x219, seventeen seconds after the last hook registered, with no limits
line yet and a PlayerController being constructed in the same instant.
Causality is not proven -- the callstack is ntdll only -- but an
unbounded rescan is worth removing on its own merits. Every healthy run
on record latches within about five attempts; this is far past that, so
it cannot cost a slow machine its fallback writes.

### `GUARDED_MISSION_NAMES`

Missions that auto-assign a character *in addition to* the player
commander. Only those put a body into the deployment area that the squad
selection did not choose, so only those keep their authored maximum.

Read from the cooked mission definitions: of 125, exactly 18 carry
CharacterRequirements and every requirement is bAutoAssign. Fourteen of
the eighteen require the player commander alone, who occupies an ordinary
squad slot and costs no extra body. These four are the entire remainder.

The 1.0.4 list plus its "/AuthoredHero/" and "HM_" substring fallback
matched twenty-one definitions, six of which carry no requirements at all.
That, not a game limit, is why free-form-looking missions were still
capped at four.

### `SCRIPTED_COMPANION_MISSION_NAMES`

Slug HQ injects Tal Rea from mission Blueprint logic rather than declaring
her in CharacterRequirements. Its cooked definition therefore looked like
an ordinary four-to-six candidate, but a live 1.1.1 report settled the
behavior: six selected operators became eight player units at combat start
and Tal Rea appeared twice. Keep these exact missions at their authored
four even when the empty/missing requirements array is readable.

Played since (2026-10-12, build 25134257): Slug HQ at six, Tel-Rea joining
before the second encounter as the mission's own Char_Hero_TelRea_Jedi_SlugHQ_C
for seven units, one of her, and a manual save at seven finishing. The
duplicate didn't reproduce, so Slug HQ left the list and ships at six.

The six AuthoredHero entries are the same shape as Slug HQ, established by
reading all 125 cooked definitions rather than by guessing:

  * Five HM definitions carry readable CharacterRequirements. Four of the
    five auto-assign two or three characters -- HM_Kabb_010, HM_Telrea_010,
    HM_Telrea_020, HM_TrickLuco_020 -- and are already guarded by
    reflection.
  * The other six are among the ten definitions UAssetAPI parses as
    RawExport. They declare nothing at all: no MaxSquadSize, and no
    requirements either. A hero mission that names no cast in its
    definition has to receive one from mission logic, which is precisely
    the route that produced two Tal Reas on Slug HQ.

HM_Jae_020 was the eleventh, and until 1.1.4 it was deliberately left out:
its requirement array reads one auto-assign, which the census recorded as
the commander alone. The array under-reports it. Reading the definitions'
own cast tags settles it -- every AuthoredHero mission names Hawks plus at
least one companion, and in every readable case the tag count equals the
requirement count except this one:

    HM_Jae_010   Hawks, JaeMordant   RawExport   guarded
    HM_Jae_020   Hawks, JaeMordant   reqs 1/1    NOT guarded

The two Jae missions are identical in shape, down to Facts.States.InRoster
.Jae. Jae therefore arrives through mission logic rather than through the
requirement array -- the Slug HQ route again. MortisVenunum reported six
selected operators becoming seven on cycle 29 when she joins at the start,
which hangs the save. With HM_Jae_020 listed the guard covers all eleven
AuthoredHero missions, which is what the cast census supports directly:
none of them deploys a free six.

Played since (2026-10-12, build 25134257): HM_Jae_020 at six, Jae joining
partway through for seven units, an autosave and a manual save at seven both
finished and the manual one loaded back (docs/live-tests.md). Deep Cover had
already saved at seven and eight. The hang didn't reproduce, so HM_Jae_020
left the guard and ships at six from the Core pak.

1.1.0 removed the old "HM_" substring fallback because it over-matched
twenty-one definitions, six of which carried no requirements. This is not
that fallback: it is six exact names, chosen from the requirement census,
and it leaves every non-hero mission and HM_Jae_020 free to reach six.

Before 1.1.2 these six were left at four by accident -- they are reachable
only by the fallback write, and the startup sweep latched before most of
them had loaded. Making that write reliable is what exposed them: Tesel and
FoxFlight both reported duplicated named operators on 1.1.2, on missions
that deploy a fixed authored cast.

### `RESWEEP_CAP`

Ten of the 125 mission definitions serialize no MaxSquadSize override at
all -- both Cly hero missions, HM_Jae_010, HM_Kabb_020, HM_Luco_010,
HM_Trick_010, SK_Serolonis_020, SK_Vandor_015, MM_02_010_CoilReunion and
the main-story placeholder. The container cannot reach them: UAssetAPI
parses those packages as RawExport, so there is no property node to edit
and nothing to inject one beside. Their only route to six is the fallback
write, and the startup sweep latches after one pass -- so whether a mission
got six came down to whether its DataAsset happened to be resident during
that single pass, roughly thirty seconds in. kamilastone's log caught it
exactly: fallback_writes=7 against the ten that need one, and Best Served
Cold left at four while the same install handed six to everything else.
"It works on an old save" is that race, not a per-mission limit.

So the sweep runs again when the squad-selection viewmodel is constructed,
which is the moment the value is about to be read and is necessarily after
the chosen mission's definition has loaded. This is not a return to 1.0.x's
unbounded rescan: that one enumerated UObjects every five seconds forever,
including through level transitions, which is what LIMIT_ATTEMPT_CAP was
added to stop. This one is edge-triggered by a UI object being built, and
still capped.

The cap counts *idle* re-sweeps, not constructions. 1.1.2 counted every
viewmodel the galaxy map built, so a long campaign session could exhaust
sixty of them on screens where there was nothing to fix and then spend the
rest of the session unable to raise a late definition or restore a guarded
one. What the cap exists to prevent is an enumeration that runs forever
while achieving nothing; a pass that wrote or restored a value is by
definition not that, so it resets the budget. A healthy install still
stops after sixty consecutive quiet passes.

## lineup.lua: squad selection

### `MIN_SLOT_SEPARATION_SQ`

A capture is only believable when consecutive authored slots are really
apart. Before the Blueprint places them the pool sits at the origin, or one
actor holds a stale transform while the rest are still at 0/0/0; 1.0.4
cached exactly that and scattered the models. This is the only condition
the reports actually evidence, so it is the only one enforced.

### `capture_authored_layout`

The stock lineup diorama has four authored attachment slots. ShowLineup
iterates every selected character and clones every proxy actor, but its Set
Diorama Slot calls cannot place indexes 4 and 5. Reuse the four authored
positions and extrapolate along the same row so a five- or six-model lineup
stays centred and keeps character/nameplate order from left to right.

A four-model lineup is left exactly where the Blueprint put it. 1.0.4
applied the six-wide layout unconditionally, which on every four-slot
mission pushed each model one slot away from its own name plate and parked
a stale full-scale proxy outside the diorama.
Returns the layout, or nil plus a short reason for the log. The reason is
what makes a report decisive: it says whether a lineup was left alone
because the pool was unplaced or because something else refused.

### `place_lineup_models`

*Inside `place_lineup_models`, at `local captured, reason = nil, nil`:*

Capture at most once per manager. After the first pass has moved the
proxies, an authored row and a row this mod already shifted look alike:
both are evenly spaced with the same step. Re-deriving would therefore
shift the lineup one slot further left on every pass, which is the
cumulative Edit Squad drift fixed in 1.0.0. The 1.0.5 validation is what
makes the single capture trustworthy; 1.0.4 cached whatever it saw.

*Inside `place_lineup_models`, at `local fit = (AUTHORED_SLOTS - 1) / (used - 1)`:*

Fit the row into the space the game framed, rather than growing past
it. Up to 1.0.6 the overflow straddled the authored row -- six models
spanned 225 uu where the authored four span 135 -- and the outer two
were kept on screen by widening every camera in the world by 22
degrees. That widening was never scoped and never restored, so it also
widened the Appearance/Outfits camera, whose zoom is driven by moving
the camera rather than by field of view: the editor zoomed out much too
far and would not zoom in past full body. Squad select and the editor
share this stage -- these proxies are the manager's customization proxy
actors -- so the fix is to stop needing the camera at all.

The step shrinks by exactly the ratio of the gaps, so whatever the
width the outermost two models land on the authored outer slots: six
models step 27 uu where four step 45, and both rows span -68..67.

*Inside `place_lineup_models`, at `local actor_key = object_key(actor)`:*

Each proxy keeps its own character's scale, reduced by the same
ratio as the step so the models close up without overlapping. The
base is re-read whenever the Blueprint has put a new scale on the
actor -- swapping an operator into a slot brings that character's
own scale with it, and a base cached once for the manager would
keep showing the previous occupant's size. It is only reused when
the actor still carries exactly what this mod last wrote, which is
what stops the fit compounding into a row that shrinks a little on
every pass. The Blueprint never places proxies past the authored
four, so those take slot four's scale as their base, as always.

### `trim_lineup_proxies`

Hide every proxy the current lineup does not use: the ones past the incoming
slot count, and the ones whose slot holds no character. 1.0.4 bailed out
unless the incoming count was exactly six, so a four-slot mission kept the
previous lineup's fifth and sixth models on screen next to four name plates.

### `describe_proxies`

One lineup pass: lay the models out and hide the ones this lineup does not
use. Idempotent, so it is safe to run from the pre-hook, the post-hook and a
deferred tick, and it needs to be: 1.0.4 did this work only in the pre-hook,
and moving it to the post-hook alone left operators 5 and 6 unplaced.

`source` and the deduplicated result line are what make a report decisive
about which of those three paths actually did the work.
Describes the pool as it stands before this pass touches it. This used to
live in the post-hook, which meant it was never logged at all: UE4SS
registers script hooks with one id for both halves and only calls the
pre-hook, so no report could ever show the proxy positions or scales.
Diagnostics only: this builds the before_positions/before_scales text and
nothing else. It crashed the game anyway, twice on one install.

`GetClonedFromCharacter` is declared with parameters -- the cooked
Blueprint calls it as an EX_LocalVirtualFunction with a Parameters list --
and this called it with none. UE4SS answers that with
"[UFunction::setup_metamethods -> __call] UFunction expected {} parameters,
received {}", and then access-violates inside its own error formatting. The
surrounding pcall never had a chance: UE4SS raises in C++ and dies building
the message, before Lua sees an error to catch. Two live crash reports have
that exact frame (`UFunction __call` under `TArray:ForEach`), and the
`cloned_proxies=` counter it fed read 0 in every log line it ever produced.
The call is gone and the field with it.

The `ForEach` is gone too, in favour of the indexed read the rest of this
file uses. It is a second UE4SS path that raises on its own terms -- "Tried
iterating an array but the unreal property has no registered handler" --
and reaching it costs the same crash. Nothing here is worth a crash.

### `run_lineup_pass`

*Inside `run_lineup_pass`, at `local counts, positions, scales = describe_proxies(proxies, proxy_count)`:*

Described before the pass touches anything, because the result is only
known afterwards and the key includes it. The first pass legitimately
refuses an unplaced pool; keying on source alone hid whether a later
pass ever succeeded, which is why a verified log showed only refusals.

### `lineup_prehook`

Pre-hook. The pool must hold six actors before the Blueprint starts cloning.
The layout also runs here, which is where 1.0.4 ran it and where six models
demonstrably appeared: on the first pass the pool is unplaced and the
capture is refused, and on every later pass the proxies still carry the
transforms the Blueprint gave them last time. The capture validation added
in 1.0.5 is what makes reading them here safe.

*Inside `lineup_prehook`, at `local activity_slots_snapshot = snapshot_array(activity_slots_param, used)`:*

Never let the deferred closure retain activity_slots_param itself. The
crash dump from 1.1.0 records "TArray index out of range" at unwrap()
after source=pre and before source=deferred, which is the exact lifetime
failure produced by reading a hook-owned RemoteParam after return.

## placement.lua: tactical deployment

### `MOVE_UNITS_FUNCTIONS`

The relocation itself. ACombatPreparationArea::MovePlayerUnitsIntoPosition
is the native function that reads PlayerDestinations and moves the squad, so
its pre-hook is the exact instant before the squad is disturbed and its
post-hook the exact instant after. That beats guessing from a delay ladder.
BP_CombatPreparationArea overrides it, so the UFunction that actually runs
belongs to the Blueprint class, not to the native base. Hooking the base
registered cleanly and never fired once: a verified run logged
relocation_hook=true with relocation_pre=false. The BP asset carries both
names; hook whatever resolves and let the log say which one ran.

### `DEPLOYMENT_EDGE_TOLERANCE`

Whether a position is somewhere an operator can usefully be, though, is a
different question, and until 1.0.9 the same 2000 uu radius answered both.
Deployment lanes are far smaller than that: across the 89 preparation areas
in the game the authored destinations span a median of 1064 uu and 86 of
the 89 span less than 2000. So a staged position most of a lane's width
outside the lane passed as "near the deployment area" and was promoted to
a permanent destination. SK_Serolonis_020 is the reported case -- one
operator staged 906 uu outside the authored shape, in a rock, and the mod
made that its destination.

The area itself carries the answer. Its PlayerDestinations are the points
the map author marked for player deployment, so their convex hull is the
deployment lane, and a position is acceptable when it lies inside that hull
or within one tactical step of its edge.

### `MAX_REPAIR_REPORTS`

Enough lines for a report to show the whole ladder without flooding one
deployment. The count is reset by begin_deployment so an early encounter
cannot make every later encounter in the same session silent.
Raised from four in 1.0.9. A relocation can now schedule more than one
ladder, and four was already being spent inside a single mission: an
attached MM_06_090 log used all four on its first two encounters and every
fight after that was silent, which is the opposite of what this cap is for.

### `WATCHDOG_DELAYS_MS`

Prorp's 1.0.9 Serolonis log was clean through post2000, then showed an
operator at 0/0/-5513 in the eight-second final census without another
relocation firing. These later checks cover that proven gap, but use only
hard-invalid signatures so they cannot pull back an operator who has begun
moving normally after control is returned.

### `RELOCATION_COALESCE_MS`

BP_CombatPreparationArea carries two names for the relocation, and both
hooks fire for a single event within a few milliseconds of each other. A
second, genuinely separate relocation is seconds later: on SK_Kaller_025 the
squad is correct at the last repair pass, 2 s after the first relocation,
and two operators are on the rocks and at the world origin by 5 s after it.
Coalescing on time rather than on the area tells those two cases apart,
where 1.0.8's one-ladder-per-area rule could not.

### `PLACEMENT_PROFILE_MATCH_RADIUS_SQ`

Cold Metal (SK_Kaller_020_Gameplay_Alt) authors its skirmish-intro capsule
inside the broad linked tactical volume but 513 uu outside the four-point
deployment quadrilateral. One of its six initial spawn transforms can
instead put Hawks at 0/0 on the snowy hill, outside that tactical volume.
The other overflow operator has been observed at 45/-1607/96, 113 uu away,
so this is also a distinct tactical step.

Match the authored PlayerDestinations rather than a localized mission name
or a brittle UObject path. This keeps the exception pinned to the one map
whose cooked geometry proves the replacement location is intentional.

### `RESCUE`

The geometry of a derived rescue point, grouped into one table the way
REPAIR is. It was four separate locals until 1.1.4, when the file turned
out to sit exactly on Lua's 200 top-level local limit and the two heights
below would not fit beside them.

K2_SetActorLocationAndRotation can settle a few units away from the exact
request. Ten uu is enough to treat that as the same rescue point while
remaining below the smallest derived point's 29.8 uu interior clearance.
Keep this separate from MIN_UNIT_SEPARATION_SQ: one tactical tile is wider
than the inset and would accept a point that is still outside the lane.

The midpoint of an authored edge is *on* the deployment shape's boundary,
not inside it, and a boundary point is exactly where a strict inside test
or a tile snap can round the wrong way -- which is the failure being
repaired. Every derived rescue point is therefore pulled this far towards
the centroid of the four authored points. On the shortest edge any profile
uses, Kaller 025's 360 uu left edge, that is a 34 uu step inwards, which
still leaves it 174 uu from the nearest authored destination: comfortably
past MIN_DESTINATION_SEPARATION_SQ and nowhere near the next operator.
A rescue the map itself authors carries its own evidence and is used as
written, so this applies only where inset_rescues says so.

A derived rescue point takes its height by interpolating between the two
authored destinations whose edge it sits on. Where the edge is a ramp or a
staircase that is right; where it spans a cliff, nothing along it is on any
surface and interpolating invents a height in mid-air. Reject the edge
rather than guess.

Measured across the hulls of all 89 authored deployment lanes -- 335 edges,
from lab/private/destination-point-scan/mapscan.json -- the rise is under
25 uu on 56 of the 128 edges that rise at all, and runs continuously up to
about 220 with no gap that separates a slope from a step. There is no
threshold that tells those apart, so this does not try to be one: above 220
the data *is* gapped (250, 318, 400, 500, 600), and those six edges are
lanes that straddle a drop. 250 uu keeps every edge the interpolation can
reasonably serve, including Fathom's 200 uu staircase, and refuses only the
handful where it plainly cannot.

An operator standing on a destination sits a capsule height above it, and
the offset is normally measured from the operators who are doing exactly
that. When none of them is -- which is precisely the deployment that needs
rescuing, because every operator is somewhere wrong -- the measurement has
no sample and used to fall back to zero, placing every derived point one
capsule height *below* the floor. Harakiri's Fathom operator landed in a
crate and then on a ledge over the void; MortisVenunum's log asked for
Z=750 on a floor at 850-864 and the capsule settled at 865, one recovery
that happened to have something underneath it.

100 uu is the measured offset on Kaller and the larger of the two heights
the 1.0.8 profile work recorded (Fathom is nearer 70), so an unsampled
guess errs upwards: a point slightly above the floor drops onto it, a point
below it is inside geometry.

### `PLACEMENT_PROFILES`

*Inside `PLACEMENT_PROFILES`, at `destinations = {`:*

This rescue is the cooked map's own skirmish-intro capsule
transform, not a point derived from the deployment quadrilateral --
it sits 513 uu outside it -- so it is used exactly as authored and
is not inset. Its evidence is that the map spawns a player there;
the tactical-volume check after the move is what confirms it.

*Inside `PLACEMENT_PROFILES`, at `inset_rescues = true,`:*

The reported six-unit staging was the four points below, one
operator at 6369/-1393 on the rocks, and one at 0/0/261. Keep both
overflow operators inside the quadrilateral the map authors marked
for player deployment: these are the midpoints of its left and
right edges, drawn in towards the centre by RESCUE.inset. Z=500 is
the capsule centre observed at the four surrounding 400-Z
TacticalPoints.

*Inside `PLACEMENT_PROFILES`, at `inset_rescues = true,`:*

MM_06_090, preparation area 2. The report's four ordinary units
match these cooked points exactly; the two overflow positions at
22009/9775 and 22683/9694 were outside the deployment zone -- one
by 33 uu, the other by 287, which is the reported difference
between an operator that can walk back in and one that cannot.
These replacements are the midpoints of the lane's two 575 uu side
edges, drawn in by RESCUE.inset. Neither extrapolates beyond the
authored four-point shape.

### `RESCUE.max_destinations`

The expansion used to stop at six destinations, the selected squad. Story
characters that join at deployment come on top: Stillwatch is six selected
plus Trick on six authored points, so `expanded=false` and one operator stood
in the open; Deep Cover at six was seven units on six. Destinations now go to
every unit up to eight. `squadsixrescue` still expects exactly six and refuses
otherwise.

### `COVER`

Points the mod adds prefer the game's cover. For each derived point, and
`RESCUE.cover_pool` more around the lane, `BRG_TargetingFunctionLibrary.
GetNearestCoverForPoint` returns the nearest cover pocket within
`RESCUE.cover_range`: its floor, its normal (from whoever uses it towards the
cover: the side it protects) and its flags (1 low, 2 high, with step-out flags above). A pocket is
used when it's in the lane, on the navmesh, a tile from every destination,
unit and other chosen point, and faces the encounter: the direction from the
lane's centroid to its tactical volume's centre, within 60 degrees. Full cover
goes first, then half, then the derived points. Where no pocket qualifies, or
the call fails, the derived points are returned unchanged, so maps without
cover, and the tests' stand-in, behave exactly as before.

Besides the derived points, the lane is searched on a tile grid
(`RESCUE.cover_grid`, at most `cover_grid_max` points), and usable cover is
ranked by how squarely it faces the encounter. In Smugglers' Den's first area
(2026-10-12) the derived points alone found three pockets, two of them facing
sideways.

The normal's direction was first read the wrong way round, so the facing test
chose exposed cover. Smugglers' Den showed it: in the first area the operator
put into "half cover facing the enemies" was the one the player saw on the
wrong side; in the second, against enemies to +X, the player moved exactly the
three operators the mod had put in pockets with normal -X, and left the three
on the game's own points, whose normals were +X.

It applies at three sites, each logged once per deployment as
`cover site=...`: the staging rescue (`staging`), the expansion's off-lane
fallback (`off_lane`), and positions staged inside the lane (`in_lane`), where
cover spots now come before the staged positions for the destinations a rescue
hasn't filled.

Tried in Rescue Jae Mordant through ZC Sandbox before writing this: the query
answered mid-mission (`LowCover` facing -Y at one operator's tile; a full-
height pocket with both step-outs 10 uu from another). Confirmed in
Smugglers' Den: the cover is there at `TriggerPreCombat`, and UE4SS returns the
out struct's nested vectors readably (`errors=0 unreadable=0`).

### `COVER.improve`

The `improve_game_spots` setting (on by default, MXM/settings.lua). Smugglers'
Den's second area showed the game's own points beside cover with its back to
the enemies, so the mod moves them as it places its own: each authored
destination with no cover facing the encounter within `cover_here_range`
moves to the best usable cover within `cover_improve_range` (searched around
it at `cover_improve_offsets` in eight directions): full before half, then
facing more squarely, then nearer. The same usability rules as the added
points apply, plus a tile from every other destination.

It runs once per area, at the first `ensure_player_destinations` and only
before the relocation has started, so the game walks the squad straight onto
the new spots. It needs the encounter's direction (`COVER.forward`), and it
skips areas with a fixed layout or a matching profile: both identify their map
by the authored points, and their spots were placed by hand. The replacements
are new actors, as the fixed layouts' are; they are not marked synthesised,
so the repair still treats a squad no bigger than the area's destinations as
the game's own deployment. It applies at every squad size, since the player
asked for it: a four-operator squad's spots move too.

The setting is read through the Mixamoo Mod Config Manager client
(Scripts/MXM.lua, unmodified, the copy Off Duty, Skip Space Travel and Fast
Resonance ship). Without the manager the schema's defaults apply. The tests
stub the client (tests/ue4ss_mock.lua): the real one polls its values file on
a loop that never stops, which the bootstrap test would count against the
maintenance loop.

### `COVER.markers`

The `debug_cover_markers` setting (off by default). Unreal's DrawDebug calls
are stripped from the shipping build: a sphere and a box drawn through ZC
Sandbox in Smugglers' Den showed nothing. A decal with the radial targeting
material showed, but its colour is the game's global UI colour, not its
`Color` parameter, in both the preset and the base material. The game's own
cover marker works: `BP_UI_CoverPoint_ScriptCreated`, given a
`RepresentedPocket` and asked to `VisualizePocket`, draws `BP_UI_Cover_Wall`
pieces whose material (`M_UI_CoverWall`) takes `Base Color`; its
`NormalizedDistance` fades it with the cursor, so it is set to 1. Drawn by
hand that way, the wall showed green.

The mod gives each marker a one-segment pocket built from the cover's floor
and normal (a tile wide, 60 uu up), as the hand test did, rather than copying
the game's segment list. It goes in through the property's `ImportText`, the
engine's text import that ZC Sandbox's `set` uses. The first version wrote the
struct from Lua tables, appending the segment with `segments[1] = {...}`; the
game crashed at the first marker (access violation reading 0x110000000f,
SK_Serolonis_030): the appended segment's `CoverActor` pointer, which the table
didn't name, was left uninitialised, and `VisualizePocket` read it. A marker
whose pocket doesn't read back one segment is destroyed before it is drawn. Each pocket is marked once per deployment (the first
search's verdict), the walls and marker are destroyed after a minute, and the
log line `debug_markers site=...` counts them; `failed=` says why marking
stopped, if it did (no class, spawn, or the pocket couldn't be written).

### `FIXED`

Profiles rescue operators onto extra points and then add destinations where
they stand; a fixed layout replaces the area's destinations outright with
spots somebody played. It exists for areas where the authored points are
worse than hand-picked ones, and for squads larger than the mod's own six-spot
expansion handles: Deep Cover deploys the squad plus Rex, so a six-operator
squad is seven units on five authored points, and the expansion stops at six
(`WARNING: fewer destinations than deployed operators`; two shared a tile).

Deep Cover's seven spots were picked by the user, who walked the squad onto
them in game; the coordinates were read with ZC Sandbox
(`call <unit> K2_GetActorLocation`). Destinations sit about 74 uu below a
standing operator (71.8 and 77.2 on the two authored points occupied at the
time), so that is subtracted from the read heights. The heights differ on
purpose: two spots are on lower ground.

A spot on an authored destination (within 5 uu) keeps that actor, since a
mission may know its points by name: Stillwatch has
`PlayerTacticalPoint_1.2_Trick` and `..._1.5_Tel`, and Deep Cover
`TacticalPoint_Rex`. Every other spot is a new actor rather than an authored
one moved, so nothing in the level changes and a mobility setting can't refuse
the move.

Stillwatch (MM_04_050_DenBattle) authors six points, and Trick joins through
the mission, so six selected are seven units. The expansion stopped at six
(`expanded=false`) and the seventh operator stood in the open; the user picked
a seventh spot on the same floor, kept after the authored six. The layout
applies whatever the squad size, since the user prefers these spots outright;
the game still decides which unit walks to which spot. The repair passes skip
a fixed area: the spots are known to work, and the forward ones sit outside
the authored lane, which `off_lane`-style checks would otherwise treat as
stranding. `squadsixrescue` still works there as the manual escape hatch.

### `at_world_origin`

An actor the placement pass never reached sits at the world origin plus its
own capsule height -- EvilPoptart1987 logged 0/0/261 for the operator that
could not move -- so the test has to ignore Z. The closest authored player
destination in the game is 224 uu from the XY origin (HM_Kabb_020), so a
100 uu radius cannot mistake a real deployment point for this.

### `remember_staged_position`

Where the game itself stood this operator up before combat. That position
is the one thing about a deployment we can trust: the game chose it, so it
is on ground the map author approved and on the tactical grid. The scan of
the cooked levels says there is no alternative to fall back on -- 53 of the
89 deployment areas author no spare TacticalPoint anywhere near the squad,
and MM_02_030, HM_Jae_010 and SK_Kaller_020, the three maps the 1.0.5
reports actually name, author none at all.

First reading wins, and only inside the staging window: once the relocation
has run, the position on offer is the broken one we are trying to undo.
`trusted` marks a position this mod chose rather than one the game staged.
The repair tests an untrusted snapshot against the authored lane before
restoring anybody to it; a trusted one is used as written, because the
rescue that produced it already argued for the location -- Cold Metal's is
the cooked map's own skirmish-intro capsule, 513 uu outside the deployment
quadrilateral.

*Inside `remember_staged_position`, at `if actor_inside_tactical_area(volume, member) == false then return end`:*

Cold Metal proves that an initial spawn is not automatically safe: it
can put Hawks on the snowy hill outside the playable volume. Never turn
a position the game itself rejects into either a repair target or a
destination candidate.

### `collect_members`

Collect the player units standing in this deployment area, and record how
the count was arrived at.

The filter is proximity to an authored destination, not world identity. A
verified mission launch logged raw=12 valid=12 in_world=0: every squad
member was readable and every one was rejected by comparing
member:GetWorld() against area:GetWorld() by name. That comparison is what
left a six-operator squad on a four-destination map with two units
relocated onto the same tile. Distance does the job the world check was
meant to do -- a unit standing in the deployment area is in the right
world, in the playable space, and on ground the map author approved -- and
unlike the world check it demonstrably works. The world name is still
recorded, as a number in the log rather than a gate on behaviour.

### `derive_rescue_points`

Where to put an overflow operator on a map that has no hand-verified
profile. The three profiles hardcode inset midpoints of authored edges;
this derives the same shape from whatever destinations the area actually
carries, so it works on all 89 preparation areas instead of three.

Z is self-calibrating. An operator standing on a destination sits a capsule
height above it -- about 100 uu on Kaller, 70 on Fathom -- so rather than
guess, take the offset from the operators who are already standing on their
destinations in this very deployment. Where none of them is, fall back to
RESCUE.capsule_height rather than to zero.

`ignore_units` drops the unit-proximity *rejection* while keeping units in
the clearance used for ordering. The repair fallback needs it: it rebuilds
this pool after the rescue has already stood operators on the points it
derived, and rejecting those points leaves it with nothing to offer. Where
a point is genuinely occupied the caller checks that itself. The expansion
path leaves it off, because a new *destination* on top of a standing
operator is a different and worse mistake.

*Inside `derive_rescue_points`, at `local rise = math.abs((first.Z or 0) - (second.Z or 0))`:*

Interpolate between the two ends of the edge rather than take the
height of the nearest destination. On a lane whose corners sit at
different heights the nearest destination to an inset midpoint can
be the one on the other level, and two points a couple of hundred
uu apart then get heights a couple of hundred uu apart -- at least
one of them inside the geometry. Harakiri's Fathom stairs are the
reported case: 1.1.3 derived 13074/2050 at Z=-200 and 12845/2050 at
Z=0 off the same staircase, and put an operator in a crate.

### `match_placement_profile`

Match a cooked four-point fingerprint after any level-instance translation
or yaw rotation. The old Cold Metal comparison used absolute coordinates,
so it silently stopped matching as soon as the same sublevel was instanced
elsewhere. Two points establish the 2-D rigid transform; all four must then
match distinct live destinations within 50 uu before a profile can act.

### `rescue_known_staging`

Some maps stage overflow operators somewhere that is technically inside
the broad tactical volume but outside the small player deployment lane.
Act only on exact cooked four-point fingerprints and place the overflow
inside that authored shape before turning those positions into destinations.

Every profile is tried, not just profiles up to the first match. The three
shipped fingerprints are provably non-congruent -- each one matches exactly
one of the game's 89 preparation areas, at scale 1 and yaw 0 -- but that is
a property of this list, not of the matcher, and a fourth profile could
quietly break it. Two profiles claiming one map means the evidence for
which correction belongs here is gone, so nothing is moved.

*Inside `rescue_known_staging`, at `local missing = math.min(#units, TARGET_SIZE) - #destinations`:*

A deployment with four authored points and six operators needs two safe
additions, not permission to move every operator whose pre-relocation
staging strip happens to sit outside the later destination polygon.
Prorp's Serolonis log proved that distinction: 1.0.9 moved four staged
operators even though only two destinations were missing.

*Inside `rescue_known_staging`, at `local authored = {}`:*

No profile: derive the lane and its rescue points from the area's own
authored destinations. A profile stays preferred where one matches --
its points come from the cooked map and are reproduced in the tests --
but every other preparation area now gets the same treatment.

*Inside `rescue_known_staging`, at `local candidate_set, settled = {}, {}`:*

Resolve occupancy before assignment. Otherwise an occupied first target
can claim the only candidate, fail the later blocked check, and starve a
free second target. A candidate within ten XY units is already settled;
any non-candidate inside a tactical tile simply makes that target
unavailable. Candidates farther than ten units are allowed to claim and
move onto their nearby target, which closes the old outside-but-skipped
band between the 30-34 uu inset and the 100 uu separation radius.

*Inside `rescue_known_staging`, at `return rescued, placed`:*

Hand back where the operators were deliberately put. The lane test that
follows exists to reject positions the *game* staged badly; a position
this pass chose on evidence -- Cold Metal's rescue is the cooked map's
own skirmish-intro capsule, 513 uu outside its deployment
quadrilateral -- must not be thrown out by it.

### `strand_reason`

*Inside `strand_reason`, at `if inside_deployment(polygon, unit.location) == false then return "off_lane" end`:*

Prefer the game's own answer. ATacticalAreaVolume::IsActorInsideTacticalArea
is what "out of bounds" means to the game; a radius around the authored
destinations is only ever an approximation of it. York117's operators
ended up under the map, which a distance test can easily call fine.
The deployment lane is asked first, because the tactical volume is the
wrong instrument for this question and three maps now prove it. It
accepted SK_Serolonis_020's operator 906 uu outside the authored shape,
in a rock, and Kaller 025's on the rocks at 6369/-1393. It describes
the battlefield the fight happens on, not the lane the squad deploys
into, so a conclusive "inside" from it is not evidence the operator can
be commanded.

### `REPAIR`

The signatures an operator cannot have arrived at by playing. `off_lane`
and `off_area` are deliberately absent: after control returns they describe
an operator the player walked somewhere, and teleporting that operator back
into the deployment lane would be the mod breaking a working mission.
One table rather than three top-level locals: the main chunk is at Lua's
200-local ceiling.

How far outside the authored lane a staged snapshot may sit and still be
somewhere to put an operator back. Beyond this it is not the edge of the
deployment, it is a different place on the map.

The overflow operators the game stages just outside a four-point lane are
the normal case and must keep working: Sambuco's fifth and sixth on
HM_Kabb_010 sit 185 and 215 uu outside a lane 395 uu across. prorp's
HM_Kabb_020 logs are the failure -- the game stages that squad on a strip
1470 to 1825 uu outside its lane, well inside the tactical volume, so every
snapshot was accepted and the repair spent the deployment hauling operators
back out to it.

1000 uu is about one whole deployment lane: across the 89 authored areas
the widest destination pair spans a median of 1060 uu. A snapshot further
outside the lane than the lane is wide is not a staging position for it.
That leaves 4.6x headroom over Sambuco and rejects prorp by 1.5x.

The reason an operator can hold for a moment on its way somewhere legal.
MovePlayerUnitsIntoPosition walks the squad rather than teleporting it, and
an operator mid-walk is outside the authored lane exactly as a stranded one
is. A live 1.1.2 log caught the consequence: the post500 and post2000 rungs
repaired the same three operators 1.5 seconds apart, to identical targets
but from very different live positions, and the squad still came to rest at
Z 11 against staged targets of Z 60-99. Both repairs fought the walk and
neither stuck.

So these two reasons now require the operator to have settled -- the same
position as the previous pass -- before anything moves it. A genuinely
stranded operator does not move, so this costs a real failure nothing; the
hard signatures below are unaffected and still repair on first sight.
`off_lane` only. `off_area` means further than 2000 uu from every authored
destination, which is a relocation that went wrong rather than a walk in
progress -- no operator walks there -- so it is still repaired on sight.

### `repair_stranded_units`

Undo a relocation that went wrong.

BP_CombatPreparationArea asks CalculateRushTargets_V2 for one target per
player unit and then moves everyone. With six operators it can return the
same target twice, or none at all, and the operator is left on a squadmate's
tile, at the world origin, or outside the deployment area. It can still
shoot and use abilities from there; it cannot move. That is every 1.0.5
report: two units at -12958/-20209 on MM_02_030, two at -25/-1112 on
HM_Jae_010, one at 0/0/261 on SK_Kaller_020.

The staged position is the first choice and stays the first choice: the
cooked levels author no spare TacticalPoint near the squad in 53 of 89
deployment areas, and none at all in the three maps above, so a staged
repair does not invent a position -- it returns the operator to one the
game itself put a unit on.

An operator with no staged position used to get nothing at all. That is
Darkened0Sky's whole mission: `staged=4` against six operators, and every
rung from post100 to watch3500 reporting `restored=0` with the two broken
operators listed as `:unstaged`. It is also Xywzel's, and it is what
`repairable=false` in the deployment_state line has been announcing since
1.1.2 without being able to act on it.

remember_staged_position refuses to enshrine a position the tactical volume
rejects, which is correct and is exactly why those two operators have no
snapshot: they were already outside when the squad was staged. So the
fallback cannot come from the squad's own history. It comes from the
authored lane instead -- the same inset edge midpoints derive_rescue_points
has been placing operators on since 1.1.0, derived from the mission's own
destinations rather than from the ones this mod appended.

Deliberately narrow: it applies only to the hard-invalid signatures, never
to `off_lane` alone, so an operator the player has walked out of the lane
is never teleported back. The two-repair budget still applies.

*Inside `repair_stranded_units`, at `local authored_points, authored_lane, authored_built = nil, nil, false`:*

Derived lazily: most passes find nothing to repair, and the ones that
do usually have a staged position to repair to. The pool is built from
the mission's own destinations, never from the ones this mod appended,
because those are the positions the operator is stranded on.

Derived ignoring where the operators currently stand. By the time a
repair rung runs, the rescue has usually already put operators on these
very points, and deriving against live positions rejected every one of
them -- which is why Harakiri's shared_tile operator read `:unstaged`
on every rung with an empty pool behind it. Occupancy is still honored,
just below, where a point can be skipped rather than never offered.
The mission's own lane, derived once and shared by the fallback below
and by the staged-position test above it.

*Inside `repair_stranded_units`, at `local offset = staged ~= nil and not staged.trusted`:*

A snapshot taken outside the authored lane is not a place to
put anybody back. prorp's HM_Kabb_020 logs are the reported
case: the game stages that squad on a strip around X=2200 to
2650, more than a thousand uu outside a lane that spans
X=-200 to 1045, and the strip is inside the tactical volume,
so remember_staged_position accepted all six. Two seconds
after the game had correctly relocated the squad into the
lane, post2000 moved four operators back out to it and
called them restored -- seven such restorations across the
run, every one of them undone by the game afterwards.

A position this mod deliberately chose is exempt: Cold
Metal's authored rescue sits 513 uu outside its own
deployment quadrilateral and is trusted on the evidence
that the map spawns a player there.

### `manual_peer_rescue`

Sambuco's two operators spawned at -80.6/40.8/-764.4, which is inside the
XY origin signature and is therefore correctly refused as a staged repair
target. His proven synchronous workaround used two different live squad
peers instead. Reproduce that only for the same tightly constrained shape:
two hard-invalid outliers, more than 2000 uu from every remaining distinct
operator, whose entire cluster is at most 1000 uu wide. The destinations
are occupied on purpose; this is an explicit command, not automatic repair.

### `ensure_player_destinations`

BP_CombatPreparationArea gathers only PlayerDestinations and then asks
CalculateRushTargets_V2 for one result per player unit. Several maps author
only four destinations. Units five and six are initially in a valid spawn
area, but the later combat-prep relocation receives no valid targets for
them and can send them to an invalid/default location. Preserve those safe
initial positions as real, distinct TacticalPoint destinations before the
relocation is calculated.

Every destination added here is a position a player unit is already
standing on. Nothing is extrapolated or interpolated, because a synthesised
point has no navigation check behind it and can land inside terrain.

*Inside `ensure_player_destinations`, at `local staging_rescued, rescued_positions = rescue_known_staging(`:*

1.0.4 asked for six destinations unconditionally, and TriggerPreCombat
can fire before the squad is populated. On a two-unit tutorial that
added two destinations the mission never authored, and the relocation
pass then moved an authored unit onto one of them, leaving it short of
the action points the script expects. A squad we cannot read is a squad
we do not touch; the bounded retries at the hook site run again once it
is populated.
Run exact map-profile rescues before the proximity-filtered squad read.
The Kaller report's sixth operator was at 0/0, more than 2000 uu from
every destination, so the old order filtered it out before the rescue
code could ever see it.

*Inside `ensure_player_destinations`, at `local squad_size = stats.squad_size or #members`:*

Ask for one destination per operator in the squad, not one per operator
that happened to pass the proximity filter. On MM_02_030 the filter read
five of six (near=5 raw=6), so the first pass -- the only pass
guaranteed to run before the game relocates anybody -- settled for five
destinations and stopped. The filter still decides which positions are
safe to reuse; it no longer decides how many are needed.

*Inside `ensure_player_destinations`, at `table.sort(candidates, function(left, right)`:*

Positions this pass deliberately moved inside the lane are the safest
destination additions available, so consume them first. Without this,
the generic rescue moved the two candidates nearest its targets and the
furthest two untouched staging-strip positions won the descending sort
below, becoming the actual destinations instead.

*Inside `ensure_player_destinations`, at `local missing = desired - #valid_destinations`:*

Darkened0Sky's Lothal crisis: four authored points, six operators, and
both additions taken from positions outside the authored lane. Two
operators deployed where the tactical volume went on to refuse them,
and neither could be commanded again -- `outside_lane=2` in the
expansion line, then `outside_volume:unstaged restored=0` on every
repair rung.

Cold Metal is the case that says an off-lane position is not
automatically wrong. One of its two additions is a position this pass
deliberately rescued into the lane; the other sits 605 uu outside a
quadrilateral that understates the map's real deployment area, and has
never been reported as stuck. So the discriminator is not "this
candidate is off-lane". It is "every position this pass is about to
add is off-lane, and not one of them was rescued there" -- no evidence
left that the authored lane is wider than its four points. Cold Metal
keeps a trusted addition and keeps its behaviour; Darkened0Sky's had
none, and gets interior points derived from the authored shape instead.

Derived points are prepended rather than substituted. If the lane
yields fewer than are needed, the original candidates still get their
turn: an operator with a destination somewhere is better off than an
operator the game never assigned one to.

*Inside `ensure_player_destinations`, at `if lane ~= nil and inside_deployment(lane, candidate.location) == false then`:*

Count, but do not reject, a position outside the authored lane.
Rescued positions are explicitly consumed first, so a four-to-six
expansion that produced two safe interior points finishes before an
untouched staging-strip position can become a destination.

Rejecting here as well would cost more than it saves. Cold Metal's
second overflow operator stages 605 uu outside its quadrilateral,
next to the map's own skirmish-intro capsule, and has never been
reported as stuck -- four authored points understate that map's
real deployment area. Refusing it a destination would take away a
working position and give nothing back. The count makes the case
visible in a log instead of guessing at it.

*Inside `ensure_player_destinations`, at `local moved, accepted = pcall(function()`:*

1.0.5 accepted any call that did not throw. A teleport the
engine declines returns false silently, leaving the point
at the origin it was spawned at -- which is where
EvilPoptart1987's fifth operator was found, at 0/0/261.

### `report_mission_placement`

Read-only. A second reporter hit an out-of-bounds spawn on an ordinary
mission, so the auto-assign guard alone does not explain every case. This
records the numbers needed to decide the real fix: how many units the squad
actually has, how many destinations the deployment area authored, and where
each unit ended up. It writes nothing and hooks nothing; the gate is a
single FindFirstOf so it costs almost nothing outside a mission.

### `register_rescue_command`

A synchronous, deliberately narrow escape hatch for a player who can see
that deployment has failed. A complete snapshot uses the normal repair but
ignores the automatic two-attempt budget: explicit player confirmation is
the safeguard that budget otherwise substitutes for. If the bad operators
spawned at the origin and could never be staged, the tightly gated peer
fallback above reproduces Sambuco's proven live workaround.

*Inside `register_rescue_command`, at `local restored, stranded = repair_stranded_units(`:*

Run the repair whatever the snapshot looks like. An incomplete
snapshot used to skip straight to the peer fallback and, when
that did not match, refuse -- which is what Darkened0Sky got:
`staged=4 fallback=shape hard=0 good=6`, twice, with two
operators still off the map. The repair now has a lane-derived
target for exactly the operators a snapshot could never cover,
so the case that most needs this command is no longer the one
case that never reaches it.

*Inside `register_rescue_command`, at `if restored == 0 and stranded > 0 then`:*

strand_reason answers "off_lane" before it asks the tactical
volume, so an operator that is both off-lane and outside the
volume gets the softer label and the lane fallback declines it.
That is the ordinary rungs behaving correctly -- an off-lane
operator may simply have walked there -- but this is an explicit
command, and the hard signatures are what the peer fallback
below already runs on. Darkened0Sky's log shows the difference
exactly: `off_lane:unstaged` on every early rung, then
`outside_volume:unstaged` once the late watchdog asked.
The soft pass keeps the last word on `stranded`: it is the
wider question, and a deployment it still calls broken must not
be reported as having had nothing wrong with it.

### `on_relocation_starting`

*Inside `on_relocation_starting`, at `local short = (string.find(name, "^/Script/") and "script:" or "bp:")`:*

Report every invocation, including a name already seen in this
deployment. The repeated name is the important case: a genuinely later
relocation can use the same Blueprint entry point as the first one.
`ladder` and `coalesced` distinguish that event from the companion hook
name that fires within the 250 ms gate.

*Inside `on_relocation_starting`, at `relocation_firing_count = relocation_firing_count + 1`:*

A relocation callback for some other preparation area must not
replace the live deployment's staged snapshot. The normal placement
trigger activates a new area; without that boundary this firing is
observable but deliberately receives no repair ladder.

*Inside `on_relocation_starting`, at `local staged = 0`:*

One line saying whether the mod is in a position to help this
mission at all, emitted once per deployment.

Xywzel's operators ended up off the map after what their log
suggested was a mid-session UE4SS reload, and the session could not
be reconstructed afterwards: a runtime that has lost its staged
snapshot repairs nothing and, until now, said nothing about it
either. Every automatic repair moves a unit only to its own staged
position, so `staged` short of `squad` is the whole story -- those
operators cannot be recovered no matter what goes wrong next.
`deployment=adopted` is the matching cause: no placement trigger
opened this deployment, which is what a reset mid-mission looks
like from here.

### `register_relocation_hook`

No early return on "one of them registered". The native name resolves at
startup and the Blueprint names only once a mission level loads, so exiting
as soon as anything was registered meant the Blueprint override -- the one
that actually runs -- was never attempted. A verified run logged
relocation_hook for the native name and relocation_fired=none.

### `register_placement_triggers`

*Inside `register_placement_triggers`, at `local delays = {0, 50, 100, 250, 500, 1000,`:*

A verified run read no squad members at
any point inside two seconds, so the ladder
reaches further. Each rung is a cheap
property read and stops mattering as soon
as the expansion succeeds.

*Inside `register_placement_triggers`, at `if retry_delay >= 1000`:*

The relocation has run by the
time the squad has been readable
for a second, so from here on
every rung checks the result and
puts back anyone it stranded.
Fallback only. When the
relocation pre-hook fires it
schedules its own repairs off
the relocation itself, and
repeating them this late risks
moving an operator the player
has already taken control of.

*Inside `register_placement_triggers`, at `if retry_index == #delays`:*

Report how the last rung ended
whatever the outcome. 1.0.4
only warned when it had already
read a squad, so the case that
actually happens -- never
reading one -- logged nothing.
