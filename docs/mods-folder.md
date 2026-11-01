# Why v2 ships in `~mods`, not `Mods/`

Squad Six v2 is a Game Feature plugin, and it only works if the game activates it. From
`Content/Paks/~mods` it does: the companion `.pak` carries `Plugins/SquadSixGF.upluginmanifest`,
the plugin manager reads it at startup, the descriptor sits under `Plugins/GameFeatures/`, and
the engine activates it from `BuiltInInitialFeatureState`. From `SWZeroCompany/Mods/` nothing
can activate it. The shipping executable was read on 2026-10-25 (Windows build, mod runtime
code at about `0x92c1a95`–`0x92c74f5`).

## What the game does with `Mods/`

`UBitReactorModRuntimeSubsystem` (module `BitReactorModRuntime`):

1. Finds every `Mods/**/*.pak` and keeps one record per pak.
2. For each new pak, compares it against
   `BitReactorModRuntimeSubsystemSettings.TrackedEntitlements` (an entitlement tag and a plugin
   name). A pak whose path contains `<PluginName>SWZeroCompany-Windows.pak`, and whose
   entitlement is owned, is passed to the load step.
3. Mounts every other pak. Then it reads `AssetRegistry.bin` at the pak's mount point (inside the
   pak; a pak without one is an error), and names the descriptor `<mount point><folder>.uplugin`.
4. The load step converts that descriptor to a `file:` URL and calls
   `UGameFeaturesSubsystem`'s load. On success it asks for activation, and the record goes
   Loaded, then Active.

The game ships `TrackedEntitlements` empty, so step 4 never runs for a mod. Mods in `Mods/` are
mounted and their registry merged, which is enough for assets the game finds by type, such as
customization parts. Their Game Features never activate. The loose `.uplugin` and
`AssetRegistry.bin` next to the pak are never read by the subsystem. The engine's plugin manager
does register the loose `.uplugin` at startup as a Mod-type plugin.

## Tried on the shipping game (2026-10-25)

Each test kept 2.0.2's `.ucas`/`.utoc` and removed the `~mods` install. All three gave four
operators:

| Layout | Why it can't work |
|---|---|
| `build_gf.sh`'s `mods` layout: UAT's pak, mounted at `Mods/SquadSixGF/` | Not a Game Feature path (`IsValidGameFeaturePlugin` needs `Plugins/GameFeatures/`). Never loaded anyway. |
| Mod Studio's layout: loose `.uplugin` + registry, pak mounted at `Plugins/GameFeatures/SquadSixGF/` | Never loaded. A load would also fail `Plugin_Name_Already_In_Use`, because the loose `.uplugin` already registered the name. |
| The pak alone, mounted at `Plugins/GameFeatures/SquadSixGF/` | Never loaded: no tracked entitlement. |

An untested route would be a `Game.ini` row adding to `TrackedEntitlements`. The ownership check
comes from the entitlement manager, so it would need an entitlement the player owns. It would
also mean editing the player's config.
