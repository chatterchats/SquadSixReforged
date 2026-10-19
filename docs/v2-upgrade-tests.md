# v2 upgrade-manager tests

Build with `python3 tools/package_v2.py` after a successful `tools/build_gf.sh`.
Compatibility is now the default. Use `--clean` for the diagnostic clean archive
or `--both` to rebuild both variants.
Outputs are `dist/SquadSixReforged-2.0.0-test.1-Clean.zip` and
`dist/SquadSixReforged-2.0.0-test.1-Compatibility.zip`, with SHA-256 sidecars.
These are private upgrade-test packages, not final releases. Internal plugin paths
remain `/SquadSixGF/`; final naming is a separate change.

Both packages use the tested v2 IoStore set, deployed at the original v1 Core
paths and filenames (`Content/Paks/~mods/SquadSixReforged_Core/pakchunk99-SquadSixReforged_P.*`).
Zero Mod Manager's `commands::replaced_by` detects IoStore upgrades by container
source filenames and UE4SS upgrades by folder name. Keeping these names allows
normal replacement detection. A manifest ID alone does not instruct cleanup.
Actual installed-manager behavior remains unverified, including Mod Command and Vortex.

The clean package contains only the v2 Core plus metadata/instructions/credits.
The compatibility package adds inert replacements for all shipped v1 runtime
Lua modules at their original paths, including an empty MXM settings page. It
keeps the original runtime manifest ID and folder name to offer replacement of
that component too. It does not ship or erase `MXM/values.lua`, UE4SS, mods.txt,
other mods, or old arctco installation folders. It does not use invalid empty
Unreal containers. The stub cannot protect against a manager later redeploying
v1 over it; v2 must win any conflicts.

For each manager independently:

1. Start with its managed v1.4.3 installation, both runtime and Core enabled.
2. Remove the manually installed `SquadSixGF_P.*` trial set first. Do not run it
   alongside the test release: they contain the same Game Feature plugin.
3. Import Clean, select Update/Replace, deploy, and inspect which old files and
   manager entries remain. The old active Lua runtime must not remain enabled.
4. If it does, repeat from the managed v1 baseline with Compatibility, selecting
   both components if prompted. Confirm `Scripts/main.lua` is the retirement stub
   and the Core containers were replaced. No v1 hooks should run after restart.
5. Check startup, holotable, lineup and six-operator deployment.
6. Uninstall v2 and record whether v1 is restored or fully removed. Restoration
   is manager-dependent; do not assume no-op files delete or permanently retire v1.

Offline validation: ZIP CRC/content round trips and build-record hashes checked;
compatibility overlay onto the v1.4.3 release leaves one Core container set and
all shipped Lua modules execute as inert tables under LuaJIT without UE4SS APIs.
JSON manifests parse; JSON Schema validation was unavailable (jsonschema absent).
No live game files were changed during packaging.

## Manager-test decision

User tested the clean upgrade in Zero Mod Manager and Mod Command: both replaced
the Core pak files but left the old Lua runtime installed. Compatibility is
therefore the chosen package for the first 2.0.0 release. The retirement stubs
ship as migration aids; v2 gameplay still requires no UE4SS. Actual compatibility
upgrade behavior and Vortex remain to be confirmed; do not describe those as
tested merely because the clean-upgrade behavior is known.

## Single-entry-point upgrade confirmed; build declaration hotfix

User confirmed Zero Mod Manager replaced the old runtime folder with only the
main-only package's stubbed Scripts/main.lua. The default Compatibility package
now uses that layout (no runtime manifests, enabled.txt, MXM files, or other Lua
modules). Mod Command's behavior with the main-only layout remains unconfirmed.
The former full-stub description above documents the earlier experiment.

Default package version is now 2.0.0-test.2. Build 25898267 was added to v2 and
both v1.4.3 zcom-mod.json declarations to address the reported strict-build block.
The separate SquadSixReforged-1.4.3-Build25898267.zip changes only those two
manifest files from the original 1.4.3 ZIP; original ZIP preserved. This declares
support for installation, not a newly completed gameplay test on that build.

### test.3: runtime metadata retained

Per user request, default Compatibility now ships exactly Scripts/main.lua,
zcom-mod.json and modinfo.json in the old runtime folder. The manifests retain
community.squad-six-reforged and the V1 Runtime display name. No enabled.txt,
MXM page or other Lua modules are shipped. This supersedes test.2's metadata-free
default; --main-only remains a separate diagnostic experiment.

### test.4: preserve the original runtime title

User found Mod Command treats the modinfo.json title as upgrade identity:
"Squad Six Reforged - V1 Runtime" created a second entry. Runtime modinfo.json
now uses exactly "Squad Six Reforged", matching v1; zcom-mod.json uses the same
name and retains community.squad-six-reforged. Default version: 2.0.0-test.4.
No gameplay/container or stub changes. Existing duplicate manager entries from
previous tests need removal through their manager before retesting from v1.

### test.5: Core display name

Per user instruction, the pak component's modinfo.json title and zcom-mod.json
name are exactly "Squad Size Reforged - Core". Runtime remains "Squad Six
Reforged". IDs and deployment paths are unchanged. This spelling differs from
the original v1 Core title ("Squad Six Reforged - Core"), so Mod Command's
reported title-based replacement behavior still needs checking for this name.
