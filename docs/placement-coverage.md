# Placement against the game's maps

`tests/placement_maps_test.lua` runs `placement.lua` over all 89 playable deployment areas in
`data/mapscan.json` (from `tools/map_scan.py`). Results on game build 24874058, with the pair
candidates described below:

| Outcome | Areas |
|---------|-------|
| Overflow operators 5 and 6, staged outside the lane, are moved into it; both new destinations are inside the lane; after a relocation strands them at the origin, repair puts both back inside | 84 |
| Only one interior point available: one operator moved into the lane, the other keeps an off-lane destination (`SK_Dantooine_025`, a three-operator mission) | 1 |
| Cold Metal: its profile only rescues operators the tactical volume rejects, so the test (which has no volume) expects none moved | 1 |
| Five or six authored destinations (one or no overflow operator) | 2 |
| Collinear destinations, no lane (`Blank_Gameplay`) | 1 |

In every case no operator is left at the world origin and none shares a tile after the repair.

## Narrow lanes

Up to 1.1.4, `derive_rescue_points` only tried the inset midpoint of each lane edge. Where the
authored destinations sit close to a line, those midpoints land within a tactical tile (100 uu) of
a destination and are rejected, so an overflow operator the game stages outside the lane kept an
off-lane destination: the failure arctco's notes describe for "Darkened0Sky's Lothal crisis" (they
don't say which Lothal crisis).

When the edge points can't hold the operators past the authored destinations, the fallback now also
tries points a third, half and two thirds of the way between every pair of authored destinations
(same rules: a tile from every destination, inside the lane, heights interpolated within
RESCUE.level_tolerance), and picks the set that fits the most points. Lanes the edge points already
serve are untouched: the derived points for the other 85 lanes are byte-identical.

| Area | Missions | Interior points, before → after |
|------|----------|-----------------|
| `SK_Lothal_035_Gameplay` | SK_Lothal_035, SK_Lothal_035_Crisis | 0 → 2 |
| `SK_Lothal_050_GameplayNew` | SK_Lothal_050, OM_Crisis_Guardian_A (and MM_01_030_NotYourTurf, three operators) | 1 → 2 |
| `MM_01_010_TheSerolonisJob_Gameplay` area 1 | MM_01_010_SerolonisJob (now kept at four: tutorial, fixed squad) | 1 → 2 |
| `SK_Dantooine_025_gameplay` area 1 | SK_Dantooine_025 (three operators) | 1 → 1 |

`tests/data/derived_points.txt` pins the exact points for every lane (for the destination
expansion, the repair pool, and with nobody standing on a destination), so a future change to the
geometry shows up as a diff of that file; regenerate it with `placement_maps_test.lua <Scripts>
--write-golden` after a deliberate change and review the diff.

SK_Lothal_035's destinations range from Z 7 to 150, so its points' heights are interpolated across
that rise; in game its derived spot came out about 117 uu above the floor. In game the runtime now
puts derived points on the navmesh under them (`settle_on_floor`), so the interpolated heights in
the golden file are only what it falls back to without a navmesh. Likewise, in game a derived point
with no navmesh under it is skipped for another candidate, once the navmesh answers under the
authored destinations; the test has no navmesh, so the golden file is unaffected. (SerolonisJob area 1, a corridor about 28 uu wide, now gets two
points 101 uu apart, but the mission keeps four operators, so they aren't used.)

Some maps author two destinations closer than a tile (both Bespin lanes repeat a point exactly,
and `HM_TrickLuco_020` has a pair 99 uu apart). Neither mission deploys six.
