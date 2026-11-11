Squad Six Reforged v2.0.5

Gameplay is pak-only and does not require UE4SS. The internal plugin path remains
SquadSixGF; that is intentional and does not affect the player-facing name. Keep all three container files.

INSTALLING OR UPDATING
1. Close the game.
2. Remove any manually installed SquadSixGF_P.pak/.ucas/.utoc trial files from
   Content/Paks/~mods/. Do not load both copies.
3. Import this ZIP, use the manager's Replace/Update option and deploy it.
   For a manual install, extract into SWZeroCompany/ and replace the old Core containers.
4. Check that the old Core entry was replaced, not left alongside another pak.
5. Restart the game and check squad select, holotable range and deployment.

THE OLD UE4SS COMPONENT
Versions up to 2.0.3 also installed Binaries/Win64/ue4ss/Mods/SquadSixReforged/.
- From 2.0.0 to 2.0.3 it is a placeholder that does nothing. You can remove it.
- From v1 it is the old Lua runtime, and this ZIP does not remove or disable it. Remove it
  through your manager, or delete that folder, before playing.
Do not change UE4SS itself, mods.txt, other mods or player settings.
