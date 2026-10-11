# What the Core pak actually changes (1.1.4)

This describes arctco's 1.1.4 container. The container this repository builds differs only as
listed in the changelog (HM_Jae_020 out; SK_Serolonis_020, SK_Vandor_015, MM_02_010_CoilReunion and
the main-story placeholder in), as set in `data/missions.tsv`.

Inspected 2026-10-11 with retoc 0.1.5 against the installed game (the Windows build in
`Games/STAR WARS Zero Company (2026)`). Re-run with `tools/inspect_core.py` after any game patch.

## Summary

The Core container (`pakchunk99-ZCOMSquadSix_P`) holds 106 packages. **Each one is the game's own
cooked package with a single value changed.** Nothing was added, removed or re-authored:

| Package | Change |
|---------|--------|
| 105 mission definitions (`BitReactorMissionData`) | `MaxSquadSize` 4 → 6 (one byte) |
| `/Game/Game/UI/AC_HologramManager` | one Blueprint integer literal 3 → 5 |

Method: each package was fetched by chunk ID from both containers (`retoc get`) and compared byte
for byte. All 105 mission packages differ from the game's in exactly one byte, 4 → 6.
`tools/zen.py` parses the packages' properties, and the byte it finds for `MaxSquadSize` is
arctco's patched byte in all 105.

arctco built the pak with retoc: to-legacy, patch, to-zen. That round trip reproduces the game's
mission packages byte for byte, and `tools/build_core.py` produces all 106 of 1.1.4's packages
byte for byte from the mission table in `data/missions.tsv`.

## Mission definitions

The changed byte is the first of an adjacent int32 pair, `MaxSquadSize` then `MinSquadSize`, both
4 in the game (see `BitReactorMissionData.h`: the two properties are declared together). So in
these missions the player can bring 4–6 operators, but not fewer than 4.

Of the game's 131 mission-data packages, 6 are tables (`MissionTables/SK_Table_*`,
`MissionTable_Crisis_Pool1`), leaving 125 definitions, all of class `BrunoMissionData`. Their
squad limits, read with `tools/zen.py` (every package parses to its last byte):

| MaxSquadSize | Missions | In the 1.1.4 pak |
|--------------|----------|------------------|
| 4 | 105 skirmishes, crises and story missions | Yes, raised to 6 |
| 4 | 10 hero missions `HM_*` other than `HM_Jae_020` | No; they auto-assign Hawks plus 1–2 companions, and the runtime (`limits.lua`) guards them at 4 |
| 4 | `MM_02_050_SlugHQ` | No; Tal Rea joins through mission logic, and the runtime guards it at 4 |
| 4 | `SK_Serolonis_020`, `SK_Vandor_015`, `MM_02_010_CoilReunion`, `Mission_MainStory_Placeholder` | No; UAssetAPI couldn't read them, so the runtime raises them |
| 3 | `MM_01_030_NotYourTurf`, `MM_05_010_UmbaraRescue`, `SK_Dantooine_025`, `SK_Kaller_030` | No; three-operator missions, left alone |
| default (1) | `MM_03_010_Bespin` | No; solo mission. The value isn't serialized, so it's `BitReactorMissionData`'s default of 1 |

arctco's notes ([`runtime-notes.md`](runtime-notes.md), under `RESWEEP_CAP` and `SCRIPTED_COMPANION_MISSION_NAMES`) say ten definitions "declare nothing at all: no MaxSquadSize, and no
requirements". That's what UAssetAPI showed arctco (it parsed them as `RawExport`), not what the
packages hold. Nine of the ten serialize 4/4 and their character requirements; only Bespin omits
the value. The guard decisions still hold: the requirement census reads the same as arctco's
(every hero mission except `HM_Jae_020` auto-assigns two or three characters).

`HM_Jae_020` **is** in the pak at 6, but since 1.1.4 the runtime guards it and writes 4 back at
runtime (Jae joining mid-mission made seven units and hung saves). The pak entry is left over from
before that fix and is harmless while the guard runs.

### The pak and the Lua overlap

The runtime's `sweep_data_limits` (`limits.lua`) writes `MaxSquadSize = 6` at runtime to every loaded mission
definition that is at 4 and not guarded. The pak does the same thing earlier and more reliably,
because the sweep only reaches definitions that are already in memory. The log line
`data_container=loaded|partial|missing` reports which of the two did the work.

## AC_HologramManager

The legacy `.uexp` differs at offset 1571: bytes `1d 03 00 00 00` → `1d 05 00 00 00`, a Kismet
`EX_IntConst` 3 → 5. The package's names include `GenerateCustomizationProxies`,
`Temp_int_Loop_Counter_Variable` and `LessEqual_IntInt`, so this is almost certainly the last index
of the inclusive loop that spawns the lineup's customization proxies (0..3 → 0..5, so six proxies
instead of four). Which function holds the literal hasn't been checked with a bytecode
disassembler.

The Zen package is 24 bytes smaller than the game's. retoc's round trip drops 6 preload-dependency
entries from this Blueprint's header (in legacy form the export map's dependency counts differ
too); the export data is the game's apart from the literal. 1.1.4 shipped that way, and
`tools/build_core.py` reproduces it exactly.

## Rebuilding

`tools/build_core.py` rebuilds the pak from the installed game: it reads `data/missions.tsv`, finds
each `MaxSquadSize` by parsing the package, patches the legacy `.uexp`, packs with
`retoc to-zen --version UE5_6`, and verifies the result before writing `src/Core`. It refuses to
build if the game's missions or their limits no longer match the table, so a game patch has to be
reviewed rather than slipping through. `tools/schema.py` regenerates the property layouts from a
new `.usmap` if a patch changes the mission classes.
