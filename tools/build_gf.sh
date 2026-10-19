#!/bin/sh
# Build the Game Feature trial (unreal/SquadSixGF): Squad Six Reforged as a Game Feature plugin, no UE4SS.
#   tools/build_gf.sh [--author-only] [--install] [--layout own|manifest|mods]
# Steps:
#   1. unreal/scripts/build_gf.py authors the assets (ZComAuthoring specs in unreal/specs/gf + the GameFeatureData)
#   2. DLC cook against the BaseGame release, then IoStore packaging (UAT BuildCookRun). No content remap:
#      a Game Feature's data must stay at /SquadSixGF/SquadSixGF.
#   3. assemble three layouts:
#      own (installed by default; works, tested 2026-10-18): the manifest layout, but the .pak carries a manifest of its own, Plugins/SquadSixGF.upluginmanifest, with
#        just the plugin's entry; the game's SWZeroCompany.upluginmanifest is left alone. The plugin manager loads every
#        *.upluginmanifest in Plugins/ (ReadAllPlugins, per zcommods-58's Ghidra reading), so no per-patch rebuild.
#      manifest: one ~mods pak set, SWZeroCompany/Content/Paks/~mods/SquadSixGF_P.*. Its .pak
#        carries the game's own plugin manifest (SWZeroCompany/Plugins/SWZeroCompany.upluginmanifest) with one more
#        entry, Plugins/GameFeatures/SquadSixGF/SquadSixGF.uplugin, plus that descriptor and the plugin's registry.
#        ~mods paks mount before the plugin manager reads the manifest, so the engine discovers the plugin as a
#        built-in Game Feature (only descriptors under Plugins/GameFeatures/ qualify) and activates it from
#        BuiltInInitialFeatureState. The manifest is the game's: rebuild after every game patch.
#      mods: the folder Zero Company Mod Studio writes, SWZeroCompany/Mods/SquadSixGF/{.uplugin, AssetRegistry.bin,
#        Content/Paks/SquadSixGF_P.*}. The game mounts it and merges the registry, but never activates it
#        (tested 2026-10-18): kept for comparison.
# The Linux editor has no Windows target platform, so this cooks for Linux (Blueprints and data only).
set -eu
cd "$(dirname "$0")/.."
repo=$(pwd)
root=${SWZC_ROOT:-/run/media/chats/0c7bd812-03b4-405c-9602-31282b68fd64}
kit=${SWZC_KIT:-"$root/SWZC Merged Kit"}
engine="$root/UnrealEngine/Engine"
project="$kit/SWZeroCompany.uproject"
platform=Linux
name=SquadSixGF
logs="$repo/dist/gf-logs"
out="$repo/dist/gf"
# The game's plugin manifest, extracted from pakchunk0-Windows.pak of the build being targeted (1.2 here).
manifest=${SQUADSIXGF_MANIFEST:-/run/media/chats/e0057d4a-fe46-43eb-a837-db51979c500f/ZCRE/v1.2/data/pak_files/SWZeroCompany/Plugins/SWZeroCompany.upluginmanifest}
author_only=false install=false layout=own
while [ $# -gt 0 ]; do
    case "$1" in
        --author-only) author_only=true ;;
        --install) install=true ;;
        --layout) layout=$2; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
case "$layout" in own|manifest|mods) ;; *) echo "unknown layout $layout" >&2; exit 2 ;; esac
[ -f "$manifest" ] || { echo "game plugin manifest not found: $manifest" >&2; exit 1; }
# /tmp is a small RAM disk; keep the editor's and UAT's scratch files on the kit's drive.
export TMPDIR="$root/tmp"
mkdir -p "$logs" "$TMPDIR"
[ -f "$project" ] || { echo "SWZC Merged Kit not found: $project" >&2; exit 1; }
[ -d "$kit/Plugins/ZComAuthoring" ] || { echo "ZComAuthoring missing from the kit: rerun SWZCMergedKit/merge.py" >&2; exit 1; }
[ -e "$kit/Mods/$name" ] || ln -s "$repo/unreal/$name" "$kit/Mods/$name"
mkdir -p "$kit/Releases/BaseGame/$platform"
cp "$kit/Releases/BaseGame/Windows/AssetRegistry.bin" "$kit/Releases/BaseGame/$platform/"

echo "1/3 Authoring assets"
python3 -I "$repo/unreal/specs/gf.py"
SQUADSIXGF_SPECS="$repo/unreal/specs/gf" "$engine/Binaries/Linux/UnrealEditor-Cmd" "$project" -run=pythonscript \
    -script="$repo/unreal/scripts/build_gf.py" \
    -unattended -nop4 -nosplash -NullRHI -stdout -FullStdOutLogOutput -NoCrashDialog \
    > "$logs/author.log" 2>&1 || true
grep -E "ZCOMAUTH .*(error|warning|FAILED)|SQUADSIXGF" "$logs/author.log" | sed 's/^.*\(ZCOMAUTH\|SQUADSIXGF\)/\1/' >&2 || true
grep -q "SQUADSIXGF_RESULT ok" "$logs/author.log" || { echo "Authoring failed; see $logs/author.log" >&2; exit 1; }
$author_only && { echo "Authored (--author-only)"; exit 0; }

echo "2/3 Cooking and packaging ($platform)"
rm -rf "$kit/Packaged/$platform/SWZeroCompany/Mods/$name"
# Cook from scratch: an incremental cook once shipped a brain whose CaptureLayout bytecode didn't match its name map
# ("Bad name index 16777216/323" loading /SquadSixGF/BP_SquadSixBrain, 2026-10-18).
rm -rf "$repo/unreal/$name/Saved/Cooked"
NuGetAudit=false "$engine/Build/BatchFiles/RunUAT.sh" -ScriptsForProject="$project" BuildCookRun \
    -project="$project" -nop4 -utf8output -unattended -nocompileeditor -skipbuildeditor \
    -platform=$platform -clientconfig=Shipping -cook -stage -pak -iostore \
    -dlcname=$name -DLCPakPluginFile -basedonreleaseversion=BaseGame \
    -AdditionalCookerOptions="-AllowUncookedAssetReferences" \
    -archive -archivedirectory="$kit/Packaged" > "$logs/cook.log" 2>&1 \
    || { tail -20 "$logs/cook.log" >&2; echo "Cook failed; see $logs/cook.log" >&2; exit 1; }

echo "3/3 Assembling $out"
staged="$kit/Packaged/$platform/SWZeroCompany/Mods/$name"
paks="$staged/Content/Paks/$platform"
registry="$repo/unreal/$name/Saved/Cooked/$platform/SWZeroCompany/Mods/$name/AssetRegistry.bin"
[ -f "$registry" ] || { echo "no cooked AssetRegistry.bin for $name: $registry" >&2; exit 1; }
"$engine/Binaries/Linux/UnrealPak" "$paks/${name}SWZeroCompany-$platform.utoc" -List > "$logs/list.log" 2>&1
for asset in "$name.uasset" "BP_SquadSixBrain.uasset"; do
    grep -q "/$asset\"" "$logs/list.log" || { echo "missing from the container: $asset (see $logs/list.log)" >&2; exit 1; }
done
rm -rf "$out/mods" "$out/manifest" "$out/own"

# mods layout
mods="$out/mods/SWZeroCompany/Mods/$name"
mkdir -p "$mods/Content/Paks"
for ext in pak ucas utoc; do
    cp "$paks/${name}SWZeroCompany-$platform.$ext" "$mods/Content/Paks/${name}_P.$ext"
done
cp "$repo/unreal/$name/$name.uplugin" "$registry" "$mods/"

# manifest layout: UAT's IoStore pair under ~mods, with a companion .pak of our own
tilde="$out/manifest/SWZeroCompany/Content/Paks/~mods"
work="$out/manifest-work"
rm -rf "$work" && mkdir -p "$tilde" "$work"
for ext in ucas utoc; do
    cp "$paks/${name}SWZeroCompany-$platform.$ext" "$tilde/${name}_P.$ext"
done
python3 -I - "$manifest" "$repo/unreal/$name/$name.uplugin" "$work/SWZeroCompany.upluginmanifest" "$name" <<'PY'
import json, sys
game, descriptor, out, name = sys.argv[1:]
data = json.load(open(game, encoding="utf-8-sig"))
entry = f"../../../SWZeroCompany/Plugins/GameFeatures/{name}/{name}.uplugin"
data["Contents"] = [c for c in data["Contents"] if c["File"] != entry]
data["Contents"].append({"File": entry, "Descriptor": json.load(open(descriptor, encoding="utf-8"))})
with open(out, "w", encoding="utf-8", newline="\r\n") as f:
    json.dump(data, f, indent="\t")
print(f"manifest: {len(data['Contents'])} plugins, added {entry}")
PY
plugin_dir="../../../SWZeroCompany/Plugins/GameFeatures/$name"
cat > "$work/pak.txt" <<LIST
"$work/SWZeroCompany.upluginmanifest" "../../../SWZeroCompany/Plugins/SWZeroCompany.upluginmanifest" -compress
"$repo/unreal/$name/$name.uplugin" "$plugin_dir/$name.uplugin" -compress
"$registry" "$plugin_dir/AssetRegistry.bin" -compress
LIST
"$engine/Binaries/Linux/UnrealPak" "$tilde/${name}_P.pak" -create="$work/pak.txt" -platform=$platform \
    -compressionformats=Oodle -compresslevel=4 -compressmethod=Kraken > "$logs/companion-pak.log" 2>&1 \
    || { tail -5 "$logs/companion-pak.log" >&2; echo "companion pak failed; see $logs/companion-pak.log" >&2; exit 1; }
"$engine/Binaries/Linux/UnrealPak" "$tilde/${name}_P.pak" -List > "$logs/companion-list.log" 2>&1
# UnrealPak picks the common root as mount point (../../../SWZeroCompany/Plugins/); entries are relative to it.
grep -q 'mount point "../../../SWZeroCompany/Plugins/"' "$logs/companion-list.log" \
    && grep -q '"SWZeroCompany.upluginmanifest"' "$logs/companion-list.log" \
    && grep -q "\"GameFeatures/$name/$name.uplugin\"" "$logs/companion-list.log" \
    || { echo "companion pak layout unexpected; see $logs/companion-list.log" >&2; exit 1; }

# own layout: same IoStore pair, companion .pak with a one-entry manifest of the plugin's own
own="$out/own/SWZeroCompany/Content/Paks/~mods"
mkdir -p "$own"
for ext in ucas utoc; do cp "$tilde/${name}_P.$ext" "$own/"; done
python3 -I - "$manifest" "$repo/unreal/$name/$name.uplugin" "$work/$name.upluginmanifest" "$name" <<'PY'
import json, sys
game, descriptor, out, name = sys.argv[1:]
entry = f"../../../SWZeroCompany/Plugins/GameFeatures/{name}/{name}.uplugin"
data = {"Contents": [{"File": entry, "Descriptor": json.load(open(descriptor, encoding="utf-8"))}]}
with open(out, "w", encoding="utf-8", newline="\r\n") as f:
    json.dump(data, f, indent="\t")
PY
sed "s#^\"$work/SWZeroCompany.upluginmanifest\" \"../../../SWZeroCompany/Plugins/SWZeroCompany.upluginmanifest\"#\"$work/$name.upluginmanifest\" \"../../../SWZeroCompany/Plugins/$name.upluginmanifest\"#" "$work/pak.txt" > "$work/own.txt"
grep -q "$name.upluginmanifest" "$work/own.txt" || { echo "own pak list wrong: $work/own.txt" >&2; exit 1; }
"$engine/Binaries/Linux/UnrealPak" "$own/${name}_P.pak" -create="$work/own.txt" -platform=$platform \
    -compressionformats=Oodle -compresslevel=4 -compressmethod=Kraken > "$logs/own-pak.log" 2>&1 \
    || { tail -5 "$logs/own-pak.log" >&2; echo "own pak failed; see $logs/own-pak.log" >&2; exit 1; }
"$engine/Binaries/Linux/UnrealPak" "$own/${name}_P.pak" -List > "$logs/own-list.log" 2>&1
grep -q "\"$name.upluginmanifest\"" "$logs/own-list.log" && ! grep -q '"SWZeroCompany.upluginmanifest"' "$logs/own-list.log" \
    || { echo "own pak layout unexpected; see $logs/own-list.log" >&2; exit 1; }
rm -rf "$work"
( cd "$out" && find mods manifest own -type f | sort | xargs sha256sum ) > "$out/SHA256SUMS"
cat "$out/SHA256SUMS"

if $install; then
    game=${SWZC_GAME:-$(cat "$kit/GameInstallDirectory.txt")}
    # Only one layout at a time: both would mount the same packages twice.
    rm -rf "$game/SWZeroCompany/Mods/$name"
    rm -f "$game/SWZeroCompany/Content/Paks/~mods/${name}_P".*
    cp -r "$out/$layout/SWZeroCompany/." "$game/SWZeroCompany/"
    echo "Installed the $layout layout into $game/SWZeroCompany"
fi
