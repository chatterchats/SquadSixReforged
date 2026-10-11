# What the Core pak actually changes (1.1.4)

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
for byte. All 105 mission packages differ from the game's in exactly one byte, 4 → 6. Converting
them to legacy `.uasset/.uexp` (`retoc to-legacy`, with the game containers alongside so imports
resolve) gives identical headers and the same single byte in `.uexp`.

## Mission definitions

The changed byte is the first of an adjacent int32 pair, `MaxSquadSize` then `MinSquadSize`, both
4 in the game (see `BitReactorMissionData.h`: the two properties are declared together). So in
these missions the player can bring 4–6 operators, but not fewer than 4.

Of the game's 131 mission-data packages, 6 are tables (`MissionTables/SK_Table_*`,
`MissionTable_Crisis_Pool1`), leaving 125 definitions. 105 are in the pak. The other 20 are:

| Missions | Why they aren't in the pak |
|----------|----------------------------|
| `HM_Kabb_010`, `HM_Telrea_010`, `HM_Telrea_020`, `HM_TrickLuco_020`, `MM_02_050_SlugHQ` | Scripted extra characters; `main.lua` guards them at 4 |
| `HM_Cly_010`, `HM_Cly_020`, `HM_Jae_010`, `HM_Kabb_020`, `HM_Luco_010`, `HM_Trick_010` | Hero missions with no squad-size override; guarded at 4 by name |
| `SK_Serolonis_020`, `SK_Vandor_015`, `MM_02_010_CoilReunion`, `Mission_MainStory_Placeholder` | arctco's tool (UAssetAPI) read them as `RawExport` and couldn't edit them; `main.lua` raises them at runtime |
| `MM_01_030_NotYourTurf`, `MM_05_010_UmbaraRescue`, `SK_Dantooine_025`, `SK_Kaller_030` | Appear to be **three-operator** missions (a 3/3 pair where the others have 4/4)*; left alone |
| `MM_03_010_Bespin` | No max/min pair found by the scan*; unknown |

\* Found by a byte-pattern scan, not a property parser, so treat these as likely, not certain. The
runtime sweep only raises values that are exactly 4, so these missions keep their limit either way.

`HM_Jae_020` **is** in the pak at 6, but since 1.1.4 `main.lua` guards it and writes 4 back at
runtime (Jae joining mid-mission made seven units and hung saves). The pak entry is left over from
before that fix and is harmless while the guard runs.

### The pak and the Lua overlap

`main.lua`'s `sweep_data_limits` writes `MaxSquadSize = 6` at runtime to every loaded mission
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

The Zen package is 24 bytes smaller than the game's even though the legacy forms match apart from
that byte. The difference is in the Zen header that the repacking tool wrote, not in the asset.

## Rebuilding

Because every change is a single value in a package the game already ships, the overrides can be
rebuilt on Linux without the editor or a cook:

1. `retoc to-legacy` the needed packages out of the game's containers.
2. Patch the bytes (located by the `MaxSquadSize`/`MinSquadSize` pair, or by a proper parser).
3. `retoc to-zen --version UE5_6` into `pakchunk99-ZCOMSquadSix_P`.

The same route could also patch the four `RawExport` missions that UAssetAPI couldn't edit. A game
patch that changes any of these 106 packages needs a rebuild, because the shipped copies would
otherwise undo the patch's changes to them; `tools/inspect_core.py` catches that.
