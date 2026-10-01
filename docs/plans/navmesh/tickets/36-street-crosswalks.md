# 36: Street with sidewalks and crosswalks

**What to build:** A street in front of ticket 34's building. Weighted areas keep NPCs on the
sidewalks and send them across at crosswalks: the test bed for area costs on a realistic
layout.

**Blocked by:** 33 (map scenario harness). Stepped curbs need 34's step-height rule, so start
with flush curb cuts and add the steps once that rule has merged. The building's entrance can
be a stand-in until 34's building lands.

**Status:** done (2026-10-01, Track M3, branch `navmesh-maps-street`), merged into
`feat/navmesh`.

- [x] **The map:** a road, raised sidewalks with curbs (a small step up), crosswalks with curb
      cuts (flush ramps), a few parked cars as obstacles, and the building's entrance on one
      sidewalk.
- [x] **Areas:** road, sidewalk and crosswalk get their own area ids through the adapter.
  - Ticket 26's open item, the adapter's area-name table (research D5), would let scenarios
    say `areas.Road`. Build it here if it's small, or note the gap.
- [x] **Scenarios:**
  - a pedestrian on the far side reaches the entrance via a crosswalk;
  - with a high road cost, no path crosses the road outside a crosswalk;
  - with a road cost of 1, paths cut straight across (a negative control for the weighting);
  - a large-radius NPC still fits the curb cuts.
- [x] **Measure:**
  - the share of paths that jaywalk, at several road costs;
  - the detour overhead against a straight crossing;
  - any bends at equal-cost area edges (tickets 25 and 32), noted with a screenshot.
- [x] **A Studio screenshot** of the street with scenario paths.

## As-built (2026-10-01)

**Files:**
- `lib/navmeshadapter`: the area-name table (ruled in review.md, Track M3).
  - A text `NavArea` names a Part's area. `FromParts` returns `(desc, areas)`.
  - Names get ids from 2 up, in name order, skipping ids that numeric `NavArea`s use. The
    street gets Crosswalk 2, Road 3 and Sidewalk 4.
  - Spec and negative control in `NavMeshAdapter.spec.luau`. Mutation 87.0% for the file
    (322 mutants, 86.3% before), with no survivors on the new lines.
  - The function is self-contained (`nameAreas`). It merged beside ticket 34's `riserStrips`
    with a conflict only at the shared return.
- `tools/navmesh/maps/Harness.luau`, small changes to ticket 33's harness:
  - a scenario's `Filter` may be a function of the area-name table;
  - `Avoids` takes area names as well as ids, and the report keeps `Areas`;
  - **a fix:** `Avoids` checked only the areas on the end waypoints' floors. A straight
    crossing from one curb strip to the other lies on the road, yet neither end is on the road
    floor, so the cost-1 control passed by mistake. It now checks every floor's areas at the
    sample's height (the area's Y range). Negative control: the curbed cost-1 control failed
    before the fix.
- `tools/navmesh/maps/Street.luau`: the street, shared by `Maps/Street` (curbs) and
  `Maps/StreetFlush` (every surface at y 0). The file's header has a sketch.
  - It sits south of ticket 34's building (`Building.luau`), whose lot is the forecourt. The
    Entrance is the lobby, reached through the 8-wide doorway.
  - The road runs along X (z -36..-20), with the south sidewalk beyond it.
  - Two 6-wide crosswalks, at x -2..4 and 56..62. Cars are parked up to both sides of each
    crosswalk in both lanes, so the gap there is 6 studs.
  - **Curbs:** the road and crosswalks are 0.5 below the sidewalks. `MaxStepHeight = 1` joins
    the curb with riser strips. Each crosswalk end has a curb cut, a 2-stud wedge (14 degrees)
    tagged Crosswalk.
  - The road is split around the crosswalks, so `Avoids = { "Road" }` means "crosses only on
    a crosswalk". The forecourt is the building's ground (area 1).
- `tools/navmesh/maps/street_measure.luau [Street | StreetFlush]`: the measurements below.

**Scenarios** (`lune run tools/navmesh/maps/run.luau Street StreetFlush`). Lengths are curbed /
flush:

| Scenario | Filter | Expect | Result |
|---|---|---|---|
| far side to the entrance via a crosswalk | road cost 10 | Success, avoids Road, length >= 70 | pass, 96.4 / 80.9 (straight: 58.5) |
| road cost 10: west / east / mid start | road cost 10 | Success, avoids Road | pass, 77.8 / 76.7 / 78.2 and 77.7 / 77.4 / 78.9 |
| radius 2.5 fits the crosswalk between cars | r 2.5, road excluded | Success, avoids Road | pass, 57.9 / 57.7; curbed, down one curb cut and up the other |
| control: road cost 1 cuts straight across | road cost 1 | avoids Road, stretch <= 1.02; `MustFail = "Avoids"` | pass*: 59.2 / 58.5, enters the road |
| control: radius 3.5 does not fit between the cars | r 3.5, road excluded | Success; `MustFail = "Status"` | pass*: Partial |

- **Negative control, run by hand** (on the first, building-less layout): with both crosswalks
  tagged `Road`, all five positive scenarios fail. Restored, the map passes.
- **Curbs against flush** (`Building` alone: 268 triangles, 43 floors, 60 seams, bake 49,532 bytes):

  | | Triangles | Floors | Seams | Bake bytes | Build ms |
  |---|---|---|---|---|---|
  | StreetFlush | 358 | 43 | 60 | 59,380 | 36-64 |
  | Street (curbs) | 396 | 52 | 80 | 69,052 | 50-65 |

  - Flush, the street adds only triangles: every surface shares the building's ground plane.
  - Curbs add 9 floors (the road plane, 4 curb cuts and 4 curb strips) and 20 seams.
  - **Routes:** the same, except "far side to the entrance". It crosses at the east crosswalk
    with curbs (96.4) instead of the west one (80.9). Both routes cost only cost-1 ground: this
    is the heron gap below.
- **Found while building:**
  - The first cars were exactly 5 studs tall and didn't cut the road: the adapter drops a Part
    exactly `AgentHeight` tall (known-gaps.md, with a repro). The cars are 4.5 studs.
  - With cars on one side only, radius 3.5 fit a crosswalk. Its body may overhang the excluded
    road; only its centre line must stay on the crosswalk.

**Jaywalking and detours.** 169 crossings: 13 starts on the south sidewalk (z -43) x 13 goals on
the forecourt (z -13), x -16 to 76.
- *Jaywalk* is the share of paths entering the road.
- *Stretch* is length / straight line.
- *Excess* is length / the best crosswalk-only path (road excluded), over the paths that stay
  off the road.

| Road cost | Jaywalk, curbed / flush | Stretch mean / max, curbed | Excess mean / max, curbed | Excess max, flush |
|---|---|---|---|---|
| 1 | 94.1% / 93.5% | 1.017 / 1.098 | 1.000 / 1.000 | 1.000 |
| 1.5 | 32.5% / 39.1% | 1.105 / 1.522 | 1.005 / 1.032 | 1.073 |
| 2 | 18.3% / 23.1% | 1.132 / 1.887 | 1.004 / 1.038 | 1.073 |
| 3 | 4.7% / 11.2% | 1.201 / 2.204 | 1.000 / 1.038 | 1.073 |
| 5 | 0% / 0% | 1.233 / 2.204 | 1.000 / 1.038 | 1.073 |
| 10 | 0% / 0% | 1.233 / 2.204 | 1.000 / 1.038 | 1.073 |
| excluded | 0% / 0% | 1.236 / 2.243 | 1.000 / 1.000 | 1.000 |

- **Detour overhead:** crossing only at a crosswalk costs about 23% over the straight line on
  average, up to 2.2x for a pair midway between the crosswalks.
- **From road cost 5 up, nobody jaywalks.** The curbs lower jaywalking a little at costs 1.5-3,
  since a curbed crossing climbs two strips.
- **At road cost 1, 6% of paths still avoid the road.** For those pairs a crosswalk is on the
  straight line anyway.
- **Wrong crosswalk:** paths that stay off the road are up to 3.8% (curbed) and 7.3% (flush)
  longer than the best crosswalk route. On the first layout it reached 11.7% (S52->N44: 73.8
  against 66.1).
  - Cause: any finite cost but 1 turns heron nodes off, even for paths that never touch the
    road. Midpoint A* then picks the crosswalk.
  - Logged in known-gaps.md. The core is off limits here.

**Bends at equal-cost area edges (tickets 25 and 32).** This was measured on the first, flush
layout (no building; x 0..100). At road cost 1, where heron is on, 169 crossings were compared
with the same lot as one Part, which has no area or seam edges:
- the paths are 0.02% longer on average and 1.6% at worst (S36->N4: 45.15 against 44.46,
  through a different gap between the cars);
- 9 of 169 paths bend at a vertex that isn't an obstacle corner, against 2 with plain floor
  Parts (no `NavArea`; their joins are edges too).
- Example: S60->N12 bends at (32, 30), on the road's edge 2 studs past the car's corner at
  (30, 30): 57.43 studs against 57.11 round the corner. The bend vertex is where the mesh line
  at x 32 meets the area edge.
- Screenshot: the orange path in `.bench/navmesh/maps/StreetBend-viewport.png` (zoom:
  `StreetBend-zoom.png`). It was a scenario on that layout; it was dropped when the street moved,
  because the vertex moved with it.

**Screenshot:** `python tools/navmesh/maps/studio.py Street`, checked with the Read tool. The
frames differ in 11.6% of pixels.
- The view is top-down, with the sidewalk at the top and the building at the bottom.
- The road is its own floor (teal), edged by the curb strips. The cost-10 paths cross through
  the light crosswalk strips between the cars, into the lobby.
- The zoom (`Street-crosswalk-zoom.png`) shows the curb cuts as bands at both crosswalk ends,
  with the radius-2.5 path down the middle.
- If another session's run-in-roblox holds port 50312, the capture shows that session's window.
  Wait for the port before running. One retry was needed once because the second capture
  failed.
