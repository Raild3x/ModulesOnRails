# 36: Street with sidewalks and crosswalks

**What to build:** A street in front of ticket 34's building. Weighted areas keep NPCs on the
sidewalks and send them across at crosswalks: the test bed for area costs on a realistic
layout.

**Blocked by:** 33 (map scenario harness). Stepped curbs need 34's step-height rule, so start
with flush curb cuts and add the steps once that rule has merged. The building's entrance can
be a stand-in until 34's building lands.

**Status:** in progress (Track M3, branch `navmesh-maps-street`). The flush street, the areas,
the scenarios, the measurements and the screenshot are done. Still waiting on ticket 34: the
stepped curbs (its step-height rule) and the move in front of the real building.

- [ ] **The map:** a road, raised sidewalks with curbs (a small step up), crosswalks with curb
      cuts (flush ramps), a few parked cars as obstacles, and the building's entrance on one
      sidewalk.
  - Done flush (every surface at y 0) with a stand-in facade. Curbs wait for 34's step rule.
- [x] **Areas:** road, sidewalk and crosswalk get their own area ids through the adapter.
  - Ticket 26's open item, the adapter's area-name table (research D5), would let scenarios
    say `areas.Road`. Build it here if it's small, or note the gap.
- [x] **Scenarios:**
  - a pedestrian on the far side reaches the entrance via a crosswalk;
  - with a high road cost, no path crosses the road outside a crosswalk;
  - with a road cost of 1, paths cut straight across (a negative control for the weighting);
  - a large-radius NPC still fits the curb cuts. (Flush: fits the crosswalk between cars.
    Re-run on the ramps with the curbs.)
- [x] **Measure:**
  - the share of paths that jaywalk, at several road costs;
  - the detour overhead against a straight crossing;
  - any bends at equal-cost area edges (tickets 25 and 32), noted with a screenshot.
- [x] **A Studio screenshot** of the street with scenario paths. (Flush street; retake with
      curbs.)

## As-built (2026-10-01, flush street)

**Files:**
- `lib/navmeshadapter`: the area-name table (ruled in review.md, Track M3).
  - A text `NavArea` names a Part's area. `FromParts` returns `(desc, areas)`.
  - Names get ids from 2 up, in name order, skipping ids that numeric `NavArea`s use. The
    Street gets Crosswalk 2, Road 3 and Sidewalk 4.
  - Spec and negative control in `NavMeshAdapter.spec.luau`. Mutation 87.0% for the file
    (322 mutants, 86.3% before), with no survivors on the new lines.
- `tools/navmesh/maps/Harness.luau`, a small extension of ticket 33's harness:
  - a scenario's `Filter` may be a function of the area-name table;
  - `Avoids` takes area names as well as ids;
  - the report keeps `Areas`.
- `tools/navmesh/maps/Maps/Street.luau`: the map. Its header has a sketch.
  - A 100 x 44 lot. The road runs along X (z 14-30), with a sidewalk on each side.
  - Two 6-wide crosswalks, at x 18-24 and 76-82.
  - Cars parked up to both sides of each crosswalk in both parking lanes, so the gap there is
    6 studs.
  - A stand-in facade with a 4-stud doorway (the Entrance) on the north sidewalk.
  - The road is split around the crosswalks, so `Avoids = { "Road" }` means "crosses only on a
    crosswalk".
- `tools/navmesh/maps/street_measure.luau`: the measurements below.
  - Run: `lune run tools/navmesh/maps/street_measure.luau`.

**Scenarios** (`lune run tools/navmesh/maps/run.luau Street`):

| Scenario | Filter | Expect | Result |
|---|---|---|---|
| far side to the entrance via a crosswalk | road cost 10 | Success, avoids Road, length >= 50 | pass, 63.3 (straight: 33.5) |
| road cost 10: west / east / mid start | road cost 10 | Success, avoids Road | pass, 58.9 / 59.3 / 60.8 |
| radius 2.5 fits the crosswalk between cars | r 2.5, road excluded | Success, avoids Road | pass, 57.2 |
| equal-cost bend on the road's edge | road cost 1 | Success, length <= 57.5 | pass, 57.4 (see "Bends") |
| control: road cost 1 cuts straight across | road cost 1 | avoids Road, stretch <= 1.01; `MustFail = "Avoids"` | pass*: 34.0, enters the road |
| control: radius 3.5 does not fit between the cars | r 3.5, road excluded | Success; `MustFail = "Status"` | pass*: Partial |

- **Numbers:** FromParts 0.3 ms, Build 6.2 ms; 88 triangles, 1 floor, 0 seams; bake 10,045
  bytes; `FindPath` 0.01-0.04 ms.
- **Negative control, run by hand:** with both crosswalks tagged `Road`, all five positive
  scenarios fail. The cost-10 paths enter area 2, and radius 2.5 returns Partial. Restored, the
  map passes.
- **Found while building:**
  - The first cars were exactly 5 studs tall and didn't cut the road: the adapter drops a Part
    exactly `AgentHeight` tall (known-gaps.md, with a repro). The cars are 4.5 studs.
  - With cars on one side only, radius 3.5 fit the east crosswalk. Its body may overhang the
    excluded road, and only its centre line must stay on the crosswalk. Both crosswalks now
    have cars on both sides.

**Jaywalking and detours.** 169 crossings: 13 starts on the south sidewalk (z 7) x 13 goals on
the north one (z 37), x 4 to 96.
- *Jaywalk* is the share of paths entering the road.
- *Stretch* is length / straight line.
- *Excess* is length / the best crosswalk-only path (road excluded), over the paths that stay
  off the road.

| Road cost | Jaywalk | Stretch mean / max | Excess mean / max |
|---|---|---|---|
| 1 | 92.9% | 1.005 / 1.041 | 1.000 / 1.000 |
| 1.5 | 46.7% | 1.079 / 1.272 | 1.002 / 1.073 |
| 2 | 24.9% | 1.113 / 1.698 | 1.003 / 1.073 |
| 3 | 6.5% | 1.179 / 1.948 | 1.004 / 1.107 |
| 5 | 0% | 1.231 / 2.376 | 1.005 / 1.117 |
| 10 | 0% | 1.231 / 2.376 | 1.005 / 1.117 |
| excluded | 0% | 1.225 / 2.200 | 1.000 / 1.000 |

- **Detour overhead:** crossing only at a crosswalk costs 22.5% over the straight line on
  average, up to 2.2x for a pair midway between the crosswalks.
- **At road cost 1, 7% of paths still avoid the road.** Those are pairs where a crosswalk is
  on the straight line anyway.
- **From cost 5 up, nobody jaywalks,** but the paths are 0.5% longer than the best crosswalk
  route on average and 11.7% at worst: some take the farther crosswalk.
  - The worst is S52->N44: east, 73.8, against west, 66.1.
  - Cause: any finite cost but 1 turns heron nodes off, even for paths that never touch the
    road. Midpoint A* then picks the crosswalk. Logged in known-gaps.md; core is off limits
    here.

**Bends at equal-cost area edges (tickets 25 and 32).** At road cost 1 (heron on), 169 crossings
were compared with the same lot as one Part, which has no area or seam edges:
- the paths are 0.02% longer on average and 1.6% at worst (S36->N4: 45.15 against 44.46,
  through a different gap between the cars);
- 9 of 169 paths bend at a vertex that isn't an obstacle corner, against 2 with plain floor
  Parts (no `NavArea`; their joins are edges too).
- The scenario shows one, S60->N12. It bends at (32, 30), on the road's edge 2 studs past the
  car's corner at (30, 30): 57.43 studs against 57.11 round the corner. The bend vertex is where
  the vertical mesh line at x 32 meets the area edge.
- The screenshot shows it: the orange path in `.bench/navmesh/maps/Street-viewport.png`.

**Screenshot:** `python tools/navmesh/maps/studio.py Street`, checked with the Read tool. The
frames differ in 10.9% of pixels.
- The view is top-down, with north at the bottom (the facade and doorway).
- The cost-10 paths come round through the light crosswalk strips between the cars.
- The cost-1 control cuts straight across the dark road to the doorway.
- The radius-2.5 path threads the west crosswalk.
- If another session's run-in-roblox holds port 50312, the capture shows that session's window.
  Wait for the port before running.
