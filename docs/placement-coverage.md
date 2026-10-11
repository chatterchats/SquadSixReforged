# Placement against the game's maps

`tests/placement_maps_test.lua` runs `placement.lua` over all 89 playable deployment areas in
`data/mapscan.json` (from `tools/map_scan.py`). Results with the 1.1.4 placement rules, game build
24874058:

| Outcome | Areas |
|---------|-------|
| Overflow operators 5 and 6, staged outside the lane, are moved into it; both new destinations are inside the lane; after a relocation strands them at the origin, repair puts both back inside | 81 |
| Only one interior point available: one operator moved into the lane, the other keeps an off-lane destination | 3 |
| No interior point available: both keep off-lane destinations (`SK_Lothal_035`, used by `SK_Lothal_035` and `SK_Lothal_035_Crisis`) | 1 |
| Cold Metal: its profile only rescues operators the tactical volume rejects, so the test (which has no volume) expects none moved | 1 |
| Five or six authored destinations (one or no overflow operator) | 2 |
| Collinear destinations, no lane (`Blank_Gameplay`) | 1 |

In every case no operator is left at the world origin and none shares a tile after the repair.

## Lanes the fallback can't fill

`derive_rescue_points` only tries the inset midpoint of each lane edge. Where the authored
destinations sit close to a line, those midpoints land within a tactical tile (100 uu) of a
destination and are rejected:

| Area | Missions | Interior points |
|------|----------|-----------------|
| `SK_Lothal_035_Gameplay` | SK_Lothal_035, SK_Lothal_035_Crisis | 0 |
| `SK_Lothal_050_GameplayNew` | SK_Lothal_050, MM_01_030_NotYourTurf, OM_Crisis_Guardian_A | 1 |
| `MM_01_010_TheSerolonisJob_Gameplay` area 1 | MM_01_010_SerolonisJob | 1 |
| `SK_Dantooine_025_gameplay` area 1 | SK_Dantooine_025 (a three-operator mission) | 1 |

On these, an overflow operator the game stages outside the lane keeps an off-lane destination,
which is the failure arctco's notes describe for "Darkened0Sky's Lothal crisis" (the notes don't
say which Lothal crisis that was). MM_01_030_NotYourTurf is a three-operator mission. A wider
candidate set (for example points along the lane's interior diagonals) would cover them; the test
lists the current counts in `SHORT_LANES`, so changing the fallback shows up there.

Some maps author two destinations closer than a tile (both Bespin lanes repeat a point exactly,
and `HM_TrickLuco_020` has a pair 99 uu apart). Neither mission deploys six.
