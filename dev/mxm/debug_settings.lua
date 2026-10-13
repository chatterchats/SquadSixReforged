-- Development-only entries for the Squad Six Reforged settings page (MXM/settings.lua).
-- Never shipped: tools/sandbox_check.py install inserts these lines at the end of the installed
-- page's settings list, so a game copy gets the toggles and the release doesn't. The runtime
-- reads each with a default of off, so a release without them behaves as if they were off.
        {type = "header", name = "Debugging"},
        {key = "debug_cover_markers", type = "bool", name = "Show cover debug markers", default = false,
         desc = "At the start of an encounter, show every cover spot the mod considered for a minute: green usable, yellow too close to a squadmate or spot, red outside the deployment area or not walkable. Cover facing away from the enemies isn't marked."},
