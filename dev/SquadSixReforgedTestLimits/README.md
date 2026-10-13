# Squad Six test limits (development only)

Never shipped: it lives outside `src/`, so `tools/package.py` can't pick it up.

Sets one mission's squad limit for a test, such as a three- or four-operator mission at five,
without changing the shipped mod or its pak. It does nothing until asked, in the UE4SS console:

- `squadsixlimit` lists the loaded missions whose limit isn't six.
- `squadsixlimit <mission> <size>` sets that mission's limit, 1 to 6, for this game session.
  `<mission>` is part of the definition's name, e.g. `MM_05_010_UmbaraRescue`, and must match
  exactly one loaded mission. Use it on the galaxy map before opening squad select.

The mission's galaxy-map view model keeps its own copy of the limit, which squad select reads,
so that's set too. The override isn't saved. If the game reloads the mission definition, the override is applied
again. Restart the game to undo it. Log lines are tagged `[SQUADSIX_TESTLIMITS]`.

Squad Six Reforged only raises missions at four, so it leaves an override alone, unless the
mission is one it guards: those it puts back to four whenever it re-checks the limits.

## Install

Copy `SquadSixReforgedTestLimits` into `SWZeroCompany/Binaries/Win64/ue4ss/Mods/` on a game copy,
with the game closed. `enabled.txt` makes UE4SS load it.
