# 37: Uneven terrain: forest and river

**What to build:** Outdoor ground with slight height variation, a dense forest and a river,
built from Parts. It shows how small slopes and many obstacles affect the mesh and the paths,
and NPCs cross the river by a bridge or a ford.

**Blocked by:** 33 (map scenario harness)

**Status:** done (2026-10-02, Track M2, branch `navmesh-maps-outdoor`), except the re-run after
Track F (below). Ruled 2026-10-01: Parts first; voxel Terrain is ticket 39.

- [x] **Ground:** gently uneven, built from many slightly tilted slabs and wedges. Slopes run
      from about 1 to 10 degrees, with small steps between pieces.
- [x] **Forest:** many tree trunks (cylinders) of varied sizes, rocks, and a narrow trail
      through it.
- [x] **River:** a water channel that can't be walked, sloped banks, a bridge (raised walkable
      deck, joined by seams), and a shallow ford with a weighted area.
- [x] **Measure how slight height variation affects the mesh:**
  - floor, seam and triangle counts;
  - Build ms and bake bytes;
  - `FindPath` time and path smoothness (turns per distance).
  - Expect each tilted piece to become its own floor joined by seams. Report it, and note
    which adapter behaviour would help, such as merging near-coplanar faces or non-planar
    walkable rings (the core already supports creases).
- [x] **Scenarios:**
  - cross the forest at radius 0.5 and 2 (the large agent takes the trail or detours);
  - reach the far bank by bridge when the ford is costly, and by the ford when it's cheap;
  - no path enters the water.
- [ ] **Simplification:** this is the dense, slightly rotated input the simplification passes
      target (`simplification-plan.md`, handoff Track F). Record numbers before Track F, and
      re-run after it lands.
- [x] **A Studio screenshot** of the forest and river with paths.

## As-built (2026-10-02)

**Files:**
- `tools/navmesh/maps/Maps/ForestRiver.luau`: the map and its scenarios. `WithTilt(degrees, seed?)`
  builds the same layout at another tilt or seed.
- `tools/navmesh/bench/terrain_sweep.luau`: the measurement. `onefloor` as a third argument runs
  the deferred one-floor-per-terrain option (`TerrainOneFloor.luau`).
- Repros: `adapter_f32_seams.luau`, `core_seam_repros.luau`, `riser_lean_repro.luau` (all in
  `tools/navmesh/bench/`).

**The map** (200 x 160 studs, 823 Parts, seed 37, 5 degrees by default):
- **West meadow** (x 0-90): 9 x 16 cells of 10 studs, each cell two triangles, each triangle two
  thin WedgeParts (576 wedges). Landforms, not noise (user, 2026-10-02: "more variation ...
  flatter slopes, hills, valleys"): two hills, a diagonal valley, a ridge along the south edge
  and a gentle fall to the river, placed and sized by the seed, level along the river and on
  the pad under the bridge's west ramp. Scaled so the steepest triangle is the tilt; at 5
  degrees, 39% of the meadow is under 0.5 degrees, 77% under 2, 8% over 3.
- **River** (x 90-110, straight along Z, not meandering as sketched): 20-degree banks down to the
  channel, two Water blocks (obstacles) leaving a gap for the ford.
- **Bridge:** a deck 2.5 up from x 80 to 120 at z 36-42, a wedge ramp at each end.
- **Ford** (z 110-125): a bed slab 2 below the bank tops, `NavArea` 7.
- **East forest** (x 110-200): a flat strip, then 10-stud strips hinged edge to edge. South of z 80
  and east of x 160 a plateau stands 0.5 studs higher, reached by the step-height rule
  (`MaxStepHeight = 1`, ticket 34).
- **198 trees** (cylinders, diameter 1.2-4, at least 2 studs apart) and **30 rocks**; a 5-stud
  trail through the trees from the bridge's east end.

**Scenarios** (all pass, Lune and Studio):

| Scenario | Expect | Result |
|---|---|---|
| forest, radius 0.5 | Success, stretch <= 1.25 | 68.4 |
| forest, radius 2 | Success, length >= 72 (takes the trail) | 79.1 |
| bridge when the ford is costly (cost 50) | Success, visits Bridge, avoids area 7, >= 150 | 227.3 |
| ford when it is cheap (cost 1) | Success, visits Ford, <= 75 | 66.5 |
| west to east, radius 1 | Success | 213.0 |
| no goal in the water | NoGoal | |
| up the 0.5-stud steps onto the plateau | Success, stretch <= 1.3 | 56.8 |
| control: ford walked at cost 1 | `MustFail = "Avoids"` | pass* |
| control: the costly ford's route crosses the ford | `MustFail = "Visits"` | pass* |
| control: radius 2 as short as 0.5 | `MustFail = "MaxLength"` | pass* |

- **No path enters the water:** the sweep samples every random path every 0.5 studs; 0 points over
  the channel (outside the ford) below the bridge's height, at every tilt.
- **Robustness:** 10 seeds x 4 tilts (1, 3, 5, 10 degrees) all build and pass.

**What it took** (rulings in review.md, "Rulings during Track M2"; details in known-gaps.md):
- The adapter had three f32 tolerance bugs in its seam clipping (hinged slabs lost seams; wedge
  triangles made zero-length seams). Fixed and merged early.
- Wedge-triangle terrain still built on only 16 of 40 layouts. Three more adapter changes (join a
  floor's faces that share an edge; merge hull corners under 0.01 studs; join faces to a floor
  only within 0.001 studs of its plane) and one core change (an obstacle covering a whole seam
  closes it, instead of failing Build and Update) brought it to 40 of 40. All merged early.
- Still open: two core snapping cases (a seam end near a diagonal; obstacle corners under a grid
  step apart) that Part input no longer reaches, and the step-height rule dropping a riser where
  the upper slab leans over the step (the map starts its first plateau strip past the lean).

**The measurement** (`terrain_sweep.luau`, 3 interleaved rounds, 200 seeded random pairs at
radius 1; bench.md "Uneven terrain (ticket 37)"):

| tilt | floors | seams | triangles | cut rings | FromParts ms | Build ms | bake KB | Deserialize ms | FindPath us p50 / p95 | turns / 100 st | waypoints / 100 st |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 12 | 32 | 4,611 | 273 | 440 | 1,146 | 474 | 5.2 | 241 / 1,029 | 6.27 | 10.81 |
| 1 | 240 | 413 | 5,109 | 1,392 | 2,212 | 1,093 | 666 | 11.0 | 350 / 1,096 | 6.66 | 13.59 |
| 3 | 256 | 412 | 5,129 | 1,422 | 2,391 | 1,099 | 673 | 9.7 | 343 / 1,139 | 6.78 | 15.43 |
| 5 | 264 | 413 | 5,204 | 1,504 | 2,454 | 1,106 | 690 | 10.6 | 355 / 1,138 | 6.77 | 16.23 |
| 10 | 274 | 423 | 5,249 | 1,717 | 2,431 | 1,172 | 721 | 11.5 | 343 / 1,067 | 6.76 | 17.01 |

- **Any tilt costs most of it:** at 1 degree every tilted piece is its own floor (20x the
  floors, 13x the seams), and each piece in a valley cuts its neighbours (5x the cut rings).
  Bake +41%, Deserialize 2.1x, `FindPath` median +45%. Steeper ground adds a little more (10
  degrees: 274 floors, 1,717 cut rings, bake +52%), because fewer neighbours stay coplanar.
- **Build barely moves (-5 to +2%).** The adapter's `FromParts` takes 5x as long: its seam
  search is every face against every face.
- **Paths aren't less smooth:** turns per 100 studs go 6.3 to 6.8. They carry 26-57% more
  waypoints, one per seam crossed.
- **Before the landforms** (the first build: per-vertex noise, every triangle about as steep as
  the tilt), 1 degree gave 296 floors, 1,826 cut rings, bake +49% and `FindPath` +65%: smooth
  ground with flat stretches costs less than noise.
- **Studio** builds the same map with slightly different counts (5,229 triangles, 666 KB at 5
  degrees against Lune's 5,204 and 690 KB): Studio's Part math differs from Lune's in the last
  f32 bits.

**Which adapter behaviour would help** (ruled 2026-10-02: decide after Track F):
- **Merging near-coplanar faces into one floor: no.** It saves floors but not triangles, and a
  floor fitted to the first face moved a ramp's cut and walled the crossing (the 0.001
  tolerance above went the other way).
- **One floor per terrain** (the meadow one non-planar floor, the forest strips another),
  prototyped (asked on the noise build: floors 296 to 18, seams 441 to 40, cut rings -82%, bake
  -17%, Deserialize -30%, `FindPath` -5 to -20%). On the landform build: 18 floors, 38-40 seams,
  ~330 cut rings, bake -13 to -19%, Deserialize -13 to -28%, `FindPath` no better (p50 353-374
  us). Both: triangles +8-9%, waypoints unchanged (the funnel drapes over creases), a dropped
  crate's `Update` 5 to 8 ms (Update scans every ring on its floor), and 1 of 200 random paths
  broken in the prototype (bank to bank round the bridge; not traced).

**Re-run after Track F:** `lune run tools/navmesh/bench/terrain_sweep.luau 3` and the same with
`37 onefloor`, then compare with the table above and decide the one-floor option.

**Screenshot:** `python tools/navmesh/maps/studio.py ForestRiver --settle 45 --hold 40` (the map
takes about 6 s to build in Studio; keep `--settle` short, since the camera isn't locked and
moves if anyone touches Studio). The meadow's per-floor triangles with a wide level band along
the river, the channel and ford gap, the bridge, the trees, the plateau joined by risers, and
the scenario paths (the costly-ford route over the bridge, the cheap one through the ford).
Drawn and cleared frames differ in 13.6% of pixels.

## Highlands, the landform sampler (2026-10-02)

The user asked for far more variation ("cliffs, mountains ... overhangs and caves"; reference
charts of landforms), to start slope-merging work from a wide spread. `Maps/Highlands.luau` is a
second terrain map; ForestRiver stays as it is (it feeds the City map and the numbers above).

- **Ground:** a 320 x 320 heightfield of wedge triangles, 8-stud cells (40 x 40, 6,400 wedges),
  built by `tools/navmesh/maps/Terrain.luau` (shared with ForestRiver). Two peaks and a saddle,
  a U-shaped glacier valley, a volcano with a crater, an alluvial fan, hills, a terraced hill,
  a sinkhole, a plateau ringed by cliffs with a west ramp, a canyon through it, dunes, a mesa,
  a butte, a basin with a lake and an island, a river, and a coast with a bay, a cape, a
  peninsula on an isthmus, islands and a sea cliff. Sea level is one Water block at y 0.
- **Ordinary Parts:** a cave dug into the glacier valley's side (7 studs of headroom, walkable
  roof with a ramp), a high overhang off the plateau (walk under it), a low tilted shelf (too
  low), 30 outcrops at random turns, a natural arch over the canyon, hoodoos, a log across the
  river on two abutments, sea stacks.
- **Scenarios:** 16 plus 2 negative controls, all pass: the ramp, the arch, under and onto the
  overhang, into and onto the cave, the glacier valley, the log, the isthmus, the dunes, the
  sinkhole; and four places nobody reaches (the mesa's top, the crater, the lake island, the
  peak).
- **Slope spread** (`lune run tools/navmesh/bench/terrain_slopes.luau Highlands`; the floors'
  planes, mesh triangles, authored walkable area):

| slope | floors | mesh triangles | area |
|---|---|---|---|
| 0-0.5 | 54 | 668 | 35% |
| 0.5-2 | 174 | 298 | 7% |
| 2-5 | 190 | 383 | 7% |
| 5-10 | 176 | 453 | 7% |
| 10-15 | 198 | 514 | 7% |
| 15-20 | 152 | 349 | 6% |
| 20-25 | 178 | 420 | 7% |
| 25-30 | 135 | 349 | 6% |
| 30-35 | 98 | 282 | 4% |
| 35-40 | 205 | 400 | 8% |
| 40-45 | 185 | 378 | 7% |
| 45+ (riser strips) | 23 | 73 | 0% |

- **Numbers:** 6,449 Parts; FromParts 4.0 s, Build 2.1 s; 4,567 triangles, 1,768 floors, 2,596
  seams; bake 2,205,113 bytes.
- **What it took** (each ruled and merged early; review.md):
  - the adapter's bounding-box checks (a 3,200-triangle heightfield took over a minute);
  - leaving out walkable faces narrower than 0.5 studs (a cliff's wedges tilt their thin sides
    toward flat, which became ledges along every cliff and failed Build).
- **The log** lies level on abutments: tilted, its higher end's disk leaned over the bank and
  the step rule dropped that riser (the "riser lean" gap, again).
- **Studio:** `python tools/navmesh/maps/studio.py Highlands --settle 20 --hold 30` (the map
  takes a few seconds to build). Triangles are coloured by slope in the Parts themselves
  (green flat to grey too steep, snow on the heights).
