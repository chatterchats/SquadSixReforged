# arctco's Nexus page for Squad Six 1.1.4

The description arctco published on [Nexus Mods (mod 44)](https://www.nexusmods.com/starwarszerocompany/mods/44)
for 1.1.4, copied 2026-10-11. Kept as the record of upstream behavior and of the release history
before this repository (1.1.0–1.1.4). The wording is arctco's; only formatting was repaired where
the copy split inline paths and code across lines.

Notes from this repository, checked against the game's packages with `tools/zen.py`:

- The 1.1.3 section says six hero-mission definitions "serialize nothing at all about their
  squad". That's how UAssetAPI showed them; the packages do store MaxSquadSize 4 and their
  character requirements (see [core-pak-analysis.md](core-pak-analysis.md)). The guard decisions
  are unaffected.
- 1.1.3 removed from the container the missions the runtime puts back to four. 1.1.4 guarded
  HM_Jae_020 in the runtime but left it in the container at six; the rebuilt pak drops it.

---

## Description

Squad Six increases the maximum deployable squad size in Star Wars: Zero Company from 4 to 6 operators.

Instead of simply changing a squad-size value, the mod expands the deployment systems needed to properly support the additional operators. This includes additional activity-slot view models, presentation actors, and an adjusted squad selection layout capable of displaying all six character models and nameplates.

The mod combines an IoStore data override with a small UE4SS Lua runtime.

It does not unlock classes or modify progression, missions, abilities, equipment, encounters, or save files.

If you feel it's too easy, check out Fight Harder.

### Current testing status

The six-character squad selection screen has been visually tested, including repeated Edit Squad refreshes and runtime initialization.

A complete six-unit playthrough across every mission type and every post-mission screen has not yet been exhaustively tested. If you encounter an issue, please report the mission name, what happened, and preferably include your UE4SS log.

### Missions limited to four operators

Twelve missions intentionally keep their authored four-operator maximum because deploying six breaks their required or scripted character setup:

- Buy Cheap, Never Sleep — HM_Kabb_010
- Origin of Infection — HM_Telrea_010
- Sisters — HM_Telrea_020
- No Kings, No Masters — HM_TrickLuco_020
- Smugglers' Den — MM_02_050_SlugHQ
- Best Served Cold — HM_Cly_010 (new in 1.1.3)
- HM_Cly_020, HM_Jae_010, HM_Kabb_020, HM_Luco_010, HM_Trick_010 (new in 1.1.3)
- Rescue Jae Mordant — HM_Jae_020 (new in 1.1.4)

The first four declare additional auto-assigned characters. The rest bring a story character in through mission scripting instead, which their definitions say nothing about — raising Smugglers' Den to six produced eight player units and two copies of Tal Rea, and the six added in 1.1.3 and the one added in 1.1.4 are the same shape. Mission titles vary by language, so the internal IDs above are the reliable way to identify them.

Rescue Jae Mordant is a correction to 1.1.3, not a new restriction. Version 1.1.3 named HM_Jae_020 in writing as the one hero mission that still reaches six, on the strength of it declaring a single auto-assigned character. Its own cast data names two — Hawks and Jae — exactly as HM_Jae_010 does. Jae joins at the start, so a squad of six becomes seven and the save never finishes writing.

Best Served Cold was the same kind of correction, to 1.1.2. Version 1.1.2 raised it to six and said it was not an intended four-operator mission. The race it described was real and is still fixed, but this mission was the wrong beneficiary: it deploys a scripted cast, and six duplicates operators there.

### What changed in 1.1.4

A save that never finishes writing. Six operators on Rescue Jae Mordant became seven when Jae joined at mission start, and the save hung; five was fine. Reading the cast data for all eleven hero missions settles it — every one names the commander plus at least one story character, and in each case where the declared requirements can be read they agree with the cast, except this one. It now keeps its authored four, so all eleven do.

An operator stuck inside the scenery. Where a deployment area spans two heights — a staircase, or a catwalk over the floor beneath it — an added position took its height from whichever authored point happened to be nearest. Two positions a few metres apart could end up a whole storey apart in height, and one of them inside something. One report had an operator boxed in on the final mission, then teleported onto a ledge over the void after using Combat Recon. Height is now worked out across the deployment area instead, and an area straddling a genuine drop is left alone rather than guessed at.

An added position no longer sinks into the floor. The standing height of an operator is measured from whoever is already standing on an authored point. When nobody is — which is exactly the deployment that needs help, because every operator is somewhere wrong — that measurement had nothing to work from and came out as zero, putting every added position one operator-height underground.

The automatic repair can use the positions it derived itself. It rebuilt its list of candidate positions against wherever operators were standing at that moment, and the rescue had already stood operators on those exact positions, so the list came back empty and every repair pass reported nothing restored.

The repair no longer drags operators out of the deployment area. On maps where the game gathers the squad well outside the deployment zone before walking it in, Squad Six treated that gathering spot as the correct place to put operators back, and spent the whole deployment fighting the game's own movement. A snapshot further outside the deployment area than that area is wide is now refused.

Known limitation: Squad Six still cannot tell that an added position sits over a hole. It checks spacing and height, never the ground itself. If an operator lands somewhere impossible, the mission name and the log are genuinely useful.

### What changed in 1.1.3

Named operators no longer appear twice on missions that deploy a fixed cast. Two reporters hit this — one lost several hours to it, because with two-downs-is-death enabled, killing either copy of a duplicated character ends the run. Six hero-mission definitions serialize nothing at all about their squad: no maximum, and no character requirements either. A hero mission that names no cast in its own definition receives one from mission scripting, which is exactly how Smugglers' Den produced two copies of Tal Rea. All six now keep their authored four. This release also said HM_Jae_020 still reaches six; version 1.1.4 corrects that.

The container no longer ships six for missions the runtime has to put back to four. Those definitions were previously raised by the container and corrected at runtime, which only worked if the definition happened to be loaded when a sweep ran. They are simply absent from the container now, so there is no timing left to lose.

Operators deployed outside the playable area can now be recovered. A crisis mission placed two operators where the tactical volume refused them and the cursor would not return. Every automatic repair could only move an operator back to the position the game first stood it up in, so an operator that was never placed correctly had no repair target at all. Squad Six now falls back to a point derived from the mission's own authored deployment area, and squadsixrescue uses the same fallback instead of refusing when the snapshot is incomplete.

The repair no longer fights the game's own placement. The game walks the squad into position rather than teleporting it, and an operator mid-walk looks stranded by the same test that finds a genuinely stuck one. A log showed the same three operators pulled back twice, 1.5 seconds apart, with neither move sticking. An operator now has to stop moving before an off-lane position is treated as a fault. Positions that cannot be reached by walking — the world origin, a shared tile, a rejection by the tactical volume — are still repaired immediately.

Fixed a crash on the squad-selection screen. A diagnostic helper called a game function with the wrong number of arguments. UE4SS raises that in C++ and then crashed inside its own error reporting, so the surrounding error handling never saw it. The call only fed a counter that always read zero; it and the array iteration around it are gone.

### What changed in 1.1.2

Missions whose definition loads late now reach six operators. Ten of the game's mission definitions carry no squad-size value of their own, so the container half cannot raise them and the UE4SS runtime is their only route to six. That runtime swept once at startup, which meant a mission reached six only if its definition happened to already be in memory at that moment — roughly thirty seconds after the game loaded.

Best Served Cold (HM_Cly_010) was the reported case. It offered four slots on one save and six on another from the same install, which is the signature of that race rather than a mission limit. Version 1.1.3 supersedes this: the race was real, but Best Served Cold deploys a scripted cast and is now deliberately kept at four. The affected definitions are HM_Cly_010, HM_Cly_020, HM_Jae_010, HM_Kabb_020, HM_Luco_010, HM_Trick_010, SK_Serolonis_020, SK_Vandor_015, MM_02_010_CoilReunion and the main-story placeholder.

Version 1.1.2 runs the sweep again each time a squad-selection screen is built, which is necessarily after the chosen mission has loaded and before its limit is read. This is not a return to continuous polling: the pass is triggered by that screen being created rather than by a timer, and it is bounded. It logs nothing when there was nothing to correct, so a `limits_resweep=` line in a log means a definition genuinely arrived after startup.

A few missions are authored for three operators. That is deliberate and unchanged — Squad Six leaves them alone.

### What changed in 1.1.1

Slug HQ now keeps its authored four-operator maximum. Its DataAsset does not declare an extra character, but the mission Blueprint injects Tal Rea separately. A live report showed six selected operators becoming eight player units at combat start with two copies of Tal Rea. The guard is exact to Slug HQ and does not reduce other newly enabled missions.

Fixed a crash when opening a six-operator lineup. Version 1.1.0 retained UE4SS's temporary reflected activity-slot array in a zero-delay callback. Once the hook returned, that array could expire; the crash dump recorded TArray index out of range followed by an access violation inside UE4SS.dll. Version 1.1.1 snapshots the six stable slot objects while the hook is live, so the deferred layout pass never touches the expired hook parameter.

### Placement changes introduced in 1.1.0

Prorp's live 1.0.9 Serolonis log settled the open timing question: one relocation fired, the squad was still correct at the old two-second repair cutoff, and an operator then appeared at 0/0/-5513 in the eight-second census. There was no second relocation. Version 1.1.0 adds bounded hard-failure checks at 3.5, 5, 7, and 7.5 seconds after relocation. The 7-second pass runs before Prorp's final census; the last remains as recovery after it.

Those late checks repair only an XY world-origin position, a shared tactical tile, a conclusive rejection by the tactical volume, or two operators sharing one tile outside the authored lane. Ordinary off-lane movement is deliberately ignored after the player may have control.

The same log showed that four pre-relocation staging positions could sit outside the later destination polygon even though only two destinations were missing. Generic rescue is now capped to the missing count, so a four-to-six expansion moves at most two operators. The resulting interior positions are used first as the two added destinations instead of allowing untouched outside positions to win the next sort.

Sambuco reported Trick and HAWKS together at -80.6/40.8/-764.4 in Kabb's mission and confirmed that moving both let the mission complete. Version 1.1.0 adds the synchronous UE4SS console command squadsixrescue. A complete snapshot uses the normal repair without the automatic two-attempt limit. If the two bad operators spawned at the origin-like position and could not be staged, a last-resort fallback acts only on the exact two-remote-outliers/four-good-cluster shape and places them on two different live peers as Sambuco did. It logs `warning=shared_tiles` because that proven workaround intentionally overlaps two pairs; every looser incomplete shape is refused.

## Installation instructions

Squad Six has two halves, and both are required.

The IoStore container raises the squad limit to six. The UE4SS Lua runtime builds the two extra lineup models and fits six nameplates onto the screen. If only the container is installed, the game will offer six slots but the selection screen will break: the last slot sits off the right edge, models overlap, and the outer slots preview no character. That is not a scaling or resolution problem — it means the UE4SS half is not running. See Troubleshooting below.

### Recommended: ZCOM Mod Manager

ZCOM Mod Manager is the recommended installation method for Squad Six because it understands Zero Company's layout and installs each half to the correct destination. It also validates the IoStore container, detects conflicts, tracks the files it owns, and provides safe enable, disable, verify, and uninstall controls. Scroll down for Manual Installation if you prefer to install Squad Six manually.

1. Close Star Wars: Zero Company.
2. Install and open ZCOM Mod Manager. Let it detect the game, or select Locate game. If you choose the path manually, select the main `Star Wars Zero Company` folder — the folder that contains `SWZeroCompany` — not the `SWZeroCompany` subfolder itself.
3. Open the manager's Install page and add the single Squad Six manager bundle: `ZCOM-Squad-Six-v1.1.4-ZCOM-Manager.zip`

The manager detects Squad Six - Core and Squad Six - Runtime inside it. Review both components, retoc verification, compatibility, and any conflicts, then select Install all components. Both are required.

Updating an older manager installation: use the same single bundle. The manager matches the container filenames to the old Core entry and the ZCOMSquadSix folder to the old Runtime entry, then offers Update all components. You do not need to uninstall either old entry first.

The manager deploys them automatically to:

```
<game folder>/SWZeroCompany/Content/Paks/~mods/pakchunk99-ZCOMSquadSix_P.pak
<game folder>/SWZeroCompany/Content/Paks/~mods/pakchunk99-ZCOMSquadSix_P.utoc
<game folder>/SWZeroCompany/Content/Paks/~mods/pakchunk99-ZCOMSquadSix_P.ucas
<game folder>/SWZeroCompany/Binaries/Win64/ue4ss/Mods/ZCOMSquadSix/Scripts/main.lua
```

It also manages the `ZCOMSquadSix` entry in the correct `ue4ss/Mods/mods.txt`. You do not need to copy files into the game folders or edit `mods.txt` when using the manager.

UE4SS is still required. The manager does not redistribute UE4SS, but its Home page can install a UE4SS ZIP or 7z package that you downloaded yourself. Use Get the tested build on Nexus Mods, then Install from downloaded package….

For optional Nexus integration, open Settings → Nexus Mods downloads, save your personal Nexus API key, enable Handle nxm:// links from the browser, and then use Mod Manager Download on the Nexus page. Downloads still begin on the Nexus website; the manager then verifies and reviews them before installation.

Use the dedicated ZCOM-Manager bundle, not the Manual archive. The manager bundle contains separate component manifests so both halves can be labeled, validated, tracked, and upgraded independently.

Linux / Steam Deck: the manager supports Linux/Proton, but it does not edit Steam launch options automatically. Add the launch option shown below when running through Proton.

### Manual installation

IMPORTANT: the game has two similarly named locations. The correct mod paths are inside the nested SWZeroCompany folder.

The game root should look like this:

```
Star Wars Zero Company/
└── SWZeroCompany/
    ├── Content/Paks/
    └── Binaries/Win64/
```

Do not install into `Star Wars Zero Company/Content` or `Star Wars Zero Company/Binaries`. Those are the wrong locations. The files belong under `Star Wars Zero Company/SWZeroCompany/`.

1. Close Star Wars: Zero Company.
2. Install the required UE4SS for Star Wars Zero Company v1.0.
3. Copy these three files into `Star Wars Zero Company/SWZeroCompany/Content/Paks/~mods/`:
   `pakchunk99-ZCOMSquadSix_P.pak`, `pakchunk99-ZCOMSquadSix_P.utoc`, `pakchunk99-ZCOMSquadSix_P.ucas`
4. Copy the `ZCOMSquadSix` folder into `Star Wars Zero Company/SWZeroCompany/Binaries/Win64/ue4ss/Mods/`.
   This must be the same Mods folder that already contains `mods.txt` and the mods that came with your UE4SS install. If your `mods.txt` lives somewhere else, put the `ZCOMSquadSix` folder next to it.
5. Open `SWZeroCompany/Binaries/Win64/ue4ss/Mods/mods.txt` and add this exact line if it is not already present, above the `Keybinds : 1` line at the bottom of the file: `ZCOMSquadSix : 1`
   The download also ships `ZCOMSquadSix/enabled.txt`, which makes UE4SS load the mod even if this step is missed or applied to the wrong `mods.txt`.
6. Start the game.

The squad selection screen should now support six operators, including six character models and nameplates.

### Linux / Steam Deck

Your Steam launch options must include:

```
WINEDLLOVERRIDES="dwmapi=n,b" %command%
```

If you use MangoHud:

```
WINEDLLOVERRIDES="dwmapi=n,b" mangohud %command%
```

The download also includes an optional Linux installer:

```
./install.sh "/path/to/Star Wars Zero Company"
```

The installer performs build and checksum checks automatically.

The shell installer places the IoStore container directly inside `Content/Paks`. This is functionally equivalent to using `Content/Paks/~mods`.

### Uninstallation

For a manual installation:

1. Close the game.
2. Delete the three `pakchunk99-ZCOMSquadSix_P.*` files.
3. Delete `ue4ss/Mods/ZCOMSquadSix`.
4. Remove only this line from `mods.txt`: `ZCOMSquadSix : 1`

Linux users can alternatively run:

```
./uninstall.sh "/path/to/Star Wars Zero Company"
```

The shell uninstaller uses checksum guards to avoid removing unrelated files.

If installed through ZCOM Mod Manager, uninstall both entries from the Mods page: Squad Six - Runtime, Squad Six - Core.

## Troubleshooting

"I see six slots, but the last one is off screen and the models are wrong or missing."

This is the container-only state. The squad limit went up, but the UE4SS runtime that lays out the six models and six nameplates is not running. UI scaling and resolution settings cannot fix it.

A working UE4SS console proves UE4SS is installed, not that Squad Six loaded. To check Squad Six itself, open `SWZeroCompany/Binaries/Win64/ue4ss/UE4SS.log` and search for `ZCOM_SQUAD_SIX`. A correct install logs:

```
[ZCOM_SQUAD_SIX] loaded version=1.1.4 target_size=6
[ZCOM_SQUAD_SIX] status version=1.1.4 complete=true data_container=partial slot_hook=true proxy_hook=true lineup_hook=true placement_hook=true
```

- No `ZCOM_SQUAD_SIX` lines at all — the Lua runtime never loaded. Confirm that `main.lua` sits at `ue4ss/Mods/ZCOMSquadSix/Scripts/main.lua`, inside the same Mods folder as your `mods.txt`, and that `mods.txt` has `ZCOMSquadSix : 1` above the Keybinds line.
- `data_container=missing` — the runtime loaded but the three `pakchunk99-ZCOMSquadSix_P.*` files are not in `Content/Paks/~mods/`.
- `data_container=partial` — normal on some configurations that load late; the runtime fills in the rest itself.

On Windows, the log is still in the `SWZeroCompany/Binaries/Win64/ue4ss/` folder; it is not in a folder named `ue5ss`. Windows Steam users should not add the `WINEDLLOVERRIDES` launch option. That option is for Linux/Proton, including Steam Deck. If you are on Linux or Steam Deck and there is no `UE4SS.log` at all, the launch option above is probably missing.

When reporting a problem, pasting those `ZCOM_SQUAD_SIX` lines makes it far quicker to diagnose.

For an operator placed outside the deployment area or unable to move, include these lines in particular:

```
[ZCOM_SQUAD_SIX] player_destinations=...
[ZCOM_SQUAD_SIX] placement_rescue=...
[ZCOM_SQUAD_SIX] relocation_fired=... ladder=... coalesced=... scheduled=...
[ZCOM_SQUAD_SIX] placement_repair ...
[ZCOM_SQUAD_SIX] placement_final ...
[ZCOM_SQUAD_SIX] mission squad_members=... player_destinations=... unit_positions=...
```

If deployment is visibly broken, enter `squadsixrescue` in the UE4SS console. It runs immediately for the active six-operator deployment, even if automatic repair has already used both attempts. Look for `manual_rescue=complete mode=staged`, `mode=peer_fallback warning=shared_tiles`, `manual_rescue=noop`, or a refusal reason.

## Main features

- Increases the maximum deployable squad from 4 to 6 operators.
- Expands the deployment activity-slot view models to support six units.
- Creates the additional presentation actors required for operators 5 and 6.
- Adjusts the squad selection layout to fit all six character models and nameplates.
- Uses per-object cached lineup transforms and reapplies them after loading a save.
- Lays out five- and six-model lineups centred on the diorama, and leaves a four-model lineup exactly as the game placed it.
- Derives the authored deployment lane from each area's destination points, moves overflow operators out of rocks/off-map positions into that lane, and separates operators staged on the same tactical tile.
- Schedules bounded repair ladders per relocation and hard-failure watchdog checks at 3.5, 5, 7, and 7.5 seconds.
- Provides the guarded synchronous `squadsixrescue` console command for a visibly broken deployment.
- Applies the six-unit UI layout once instead of continuously scanning or rewriting the screen.
- Loads without a `mods.txt` edit, and logs a clear install status to your UE4SS log.
- Includes a single two-component package for the current ZCOM Mod Manager.
- Includes checksum-guarded Linux installation and uninstallation scripts.
- Does not alter classes, progression, abilities, equipment, encounter content, or save files.

## Requirements

- Star Wars: Zero Company on Steam.
- Tested game build: 24874058.
- UE4SS for Star Wars Zero Company v1.0: Nexus Mods - UE4SS for Star Wars Zero Company

Do not copy UE4SS from another game.

Install the Zero Company compatibility build linked above. Squad Six relies on its game-specific compatibility changes.

A future Zero Company update may require updated versions of both UE4SS and Squad Six.

Mods that replace the same deployment configuration assets may conflict with Squad Six.

## Compatibility / known limitations

- Tested against Steam build 24874058.
- Six-model squad selection UI has been visually confirmed.
- Six nameplates have been visually confirmed.
- Repeated Edit Squad refreshes have been tested.
- Runtime initialization is bounded and runs once rather than continuously polling the UI.
- A repaired operator may visibly snap back into place during a late watchdog check, up to 7.5 seconds after relocation.
- A complete six-unit mission across every mission type has not yet been exhaustively tested.
- Every possible end-of-mission screen has not yet been exhaustively tested.

Until broader testing is complete, keeping a backup of important saves is recommended.

If something breaks, please include the mission name, steps to reproduce the problem, and your UE4SS log when reporting it.

## Donations <3

If you like my mods, don't feel like you owe me anything. If you still want to give something back, please consider donating to one of these charities, whether they support medical research, humanitarian relief, economic hardship, environmental conservation, or another cause you care about. You're also welcome to support an open-source or community project instead.

A few causes I'd be happy to point people toward:

Humanitarian & Relief:
• Doctors Without Borders (MSF)
• International Committee of the Red Cross
• World Central Kitchen
• Palestine Children's Relief Fund (PCRF)
• Anera
• Medical Aid for Palestinians
• UNITED24

Children, Health & Conservation:
• St. Jude Children's Research Hospital
• Make-A-Wish Foundation
• Child's Play Charity
• Against Malaria Foundation
• Cancer Research UK
• Wildlife Conservation Society

Mental Health Support:
• Mind
• AFSP (American Foundation for Suicide Prevention)
• CVV (Centro de Valorização da Vida)

Open-Source & Digital Preservation:
• Software Freedom Conservancy
• Internet Archive
• Video Game History Foundation

These are humanitarian, medical, charitable, open-source and preservation projects I personally think are worth supporting. Their inclusion here isn't intended as a political endorsement.

## Shout outs

Thanks to the developers and contributors behind UE4SS and the Zero Company compatibility build for making runtime modding possible.

And thanks to the early Zero Company modding community for experimenting with the game, documenting what works, and generally poking Unreal Engine until useful things fall out. ♥
