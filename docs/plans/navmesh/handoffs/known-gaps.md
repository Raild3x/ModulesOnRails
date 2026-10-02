# NavMesh known gaps and deferred items (2026-10-01)

Read this before touching `Search`, `Clearance`, `Tiles` or `Serialize`. Each item names the
track that now owns it, where one does. Items without an owner are deferred until the user asks.

**Owned by a round-2 track:**
- **Links skip ticket 27's end check, and Storage link ids are dense:** Track E. The end check
  is closed by E3 (ticket 27, "Link and seam entries"); what it leaves is in the Track B list
  below.
- **Update time grows badly with one huge authored ring:** Track F.

**Narrowed by Track G (2026-10-01):** a Partial or Budget end is now judged with ticket 27's
barriers, as FindPath returns it (pushed off the walls). See ticket 27's "Partial and Budget
ends" section. Two kinds of end still pass unjudged; both are below.

**Found by Track G (2026-10-01):**
- **The search can return Partial for a reachable pair with an agent radius.** It closes a
  triangle the first time it is entered. If that entry is a dead end for the radius (the corner
  width onward is too narrow), a better entry can't reopen it. Changing the node model flips
  about 7 of 260 `props` radius queries between Success and Partial, both ways. The two checked
  are connected by the grid flood. One node per (triangle, entry edge) would close it; it ran
  3x slower in ticket 14's probe.
- **G3's end check costs about 70-80 us per Partial radius query on dense maps** (`props`, r
  1: 160 to 235 us). Success queries don't pay it. The cost is one push plus one barrier test
  per candidate end.

**Watch (ruled 2026-10-01, Track E): cold link landings with an agent radius.**
- Each link landing is its own search node, and its barrier verdict costs 7-13 us the first time
  per triangle and radius (then cached). With 1,000 links, a radius never seen before costs up to
  17x per `FindPath` on a dense 64-stud room (2.6x on the bench map), against 1.4x warm.
  `tools/navmesh/bench/findpath_links_cost.luau` measures it.
- The user ruled "keep as built" and asked us to watch for it. Re-measure whenever a track
  touches links, Clearance or Search, or a map (tickets 33-38) uses many generated links with
  several agent sizes.
- **If it bites:** first add a `Prewarm(mesh, radius)` that fills the cache once after load. The
  rejected options were precomputing per declared radius at Build/Update, or one node per
  triangle (which gives wrong Partials).

**Found by Track E (2026-10-01), not fixed (no owner; Funnel was Track G's):**
- **The funnel folds back at a seam line.** In `ThreeFloorStairs`, `FindPath` from the ramp
  (10.5, 0.25, 3) to the Ground just past the ramp's side (10.5, 0, 5.05) returns Success with
  a corner at the seam's end, (10, 0, 0): `Length` 8.1 at r 0 and 6.2 at r 1, against a walk of
  about 2.3. `Cost` is 4.2, so the search's corridor is fine and the string pull is wrong.
  - **Likely cause:** the path crosses the seam at x = 10, then x = 10 again on the Ground under
    the ramp. Two collinear portals crossed in opposite directions.
  - **Repro:** `lune run tools/navmesh/bench/funnel_seam_repro.luau`.
  - The link generator works round it: its walk test takes `min(Length, Cost)`.

**Found by Track M1 (2026-10-01):**
- **A path and its reverse can differ in length by about 7%.** On the building maps
  (`lune run tools/navmesh/maps/run.luau Building BuildingRamp`), Lobby to Upstairs is 55.0
  studs up the wedge ramps and 51.3 back down; with step strips it is 57.6 and 61.7 (radius
  0.5). The corridor search is not optimal (entry-edge midpoint nodes, and a triangle closes on
  first entry; see the Track G item above), so each direction can settle on a different
  corridor. No fix is planned here; it is a measurement for whoever revisits the node model.
- **`PathResult.Cost` changes meaning with the filter.** With uniform costs (or only
  exclusions, `math.huge`), it is the heron-node cost, about the path's length. Any finite
  multiplier other than 1, even on an area the path never touches, switches the search to
  edge-midpoint costs, and the same waypoints cost more.
  - **Repro:** `lune run tools/navmesh/bench/path_cost_modes.luau`. A straight 36-stud path costs 36.000 at `AreaCosts[5] = 1` or
    `math.huge`, and 36.374 at 1.0001, 2 or 5, with area 5 off the path.
  - On the building's stairs: 69.6 at uniform costs, 88.0 at `AreaCosts[5] = 1.0001` (+26%).
  - **Why it matters:** costs from two filters can't be compared, and a reroute rule compares
    exactly that ("fresh path with the elevator" against "stay off it"). Ticket 35's study
    keeps both queries in the same mode. Owner: whoever next touches Search (the heron-node
    gate is Track G's).
- **Riser strips have no area.** The adapter's step strips (ticket 34) take the default area,
  not the step Parts' `NavArea`, so a stairs multiplier misses about 1/6 of each tread. Small;
  fix when ticket 40 replaces the strips, or give a strip its upper face's area.
- **A seam can't join floors at different heights.** Build refuses it, so a stair riser needs
  the adapter's strip floor. Ticket 40 owns it.

**Found by Track M2 (2026-10-01), in the Part adapter, not the core:**
- **Tilted Parts lose their seams, or get zero-length ones that `NavMesh.Build` rejects.**
  - **Repro:** `lune run tools/navmesh/bench/adapter_f32_seams.luau`. Seven hinged slabs give
    5 of 6 seams and a Partial path. A 2 x 2 heightfield of WedgePart triangles makes
    `NavMesh.Build` throw "seam has zero length".
  - **Cause:** Part data is f32, so the hinge between two rotated Parts is collinear only to
    about 1e-5 studs. `clipSegment` (NavMeshAdapter) has three tolerances that assume exact
    input:
    1. it treats two edges as parallel only when their cross product is under 1e-12
       (unnormalised), so a hinge reads as a crossing and the clip comes back empty;
    2. a parallel edge more than 1e-6 x its length outside the ring rejects the clip, where
       f32 noise is about 1e-5;
    3. a clip that only touches a face at a corner passes as a seam of about 1e-5 studs, which
       the core rejects on its 1/256 grid.
  - **Fixed (2026-10-01, ruled; review.md "Rulings during Track M2"):** a relative parallel
    test (sine under 1e-4), the outside test in studs (`HEIGHT_TOLERANCE`, 0.01), and skipping
    clips shorter than 0.01 studs. Each has an adapter spec that fails without it. The repro now
    gives 6 seams and Success, and a 6 x 6 heightfield (72 triangles) builds and paths at 1-10
    degrees.
  - Axis-aligned levels never hit this, which is why the adapter's specs and both demos passed;
    the demo's `adapter_check` output is unchanged.
- **Wedge-triangle terrain still failed on most layouts (16 of 40 seed x tilt layouts of
  ForestRiver) after that fix. Fixed (2026-10-01, ruled) by three more adapter changes and one
  core change; 40 of 40 now build and pass:**
  - **Face join (adapter):** a floor's faces that share an edge become one ring, without the
    corners that leaves on a straight line. Two wedges made one triangle with a corner (the
    altitude's foot) mid-diagonal, which each side snapped differently.
  - **Hull corners (adapter):** cut corners closer than 0.01 studs become one; two 0.003 apart
    swapped on the core's grid and folded the ring.
  - **Coplanar tolerance (adapter):** faces join a floor within 0.001 studs of its plane, not
    0.01. A level pad that joined a floor 0.004 off its own plane moved the floor's cut from a
    ramp 0.016 past the ramp's foot, and the sliver of ground left there walled the crossing
    to any agent with a radius.
  - **Core 1, an obstacle covering a whole seam:** see below.
- **Core: three inputs that Part terrain makes and `NavMesh.Build` rejected.** One script shows
  all three: `lune run tools/navmesh/bench/core_seam_repros.luau`.
- **Core 1, fixed (2026-10-01, ruled, by Track M2): an obstacle covering a whole seam on one
  floor failed the Build, and an `Update`.**
  - **Repro (case 1):** floors A and B meet at a 4-stud seam; a crate on A covers it. Build
    threw "seam 1: does not lie on floor 'A'", and `AddObstacle` of the crate then `Update`
    failed the same way (SR13 kept the old mesh, so the crate never landed).
  - **Now:** `joinSeam` (Build.luau) closes such a seam (no portals). A seam whose middle isn't
    in or on the floor's authored walkable rings is still "does not lie on floor"; floors whose
    pieces overlap along the seam but never across it (one side) are still "don't meet across
    it", cut or not.
- **Core 2, open: a seam end near a diagonal edge can snap a grid step off it.**
  - **Repro (case 2):** two triangles share the diagonal (0,0)-(10,10), and a seam runs from
    (0,0) to (5.001953125, 5.0019459), 7e-6 studs off the diagonal. On the 1/256 grid, x rounds
    up and z rounds down, so the end lands a step off the snapped edge.
  - Before Core 1's fix this threw "does not lie on floor 'B'"; **now the seam is closed
    silently**, which is worse to debug. The case prints "ok" in the repro either way, so check
    the seam joins, not only that Build runs.
  - The core tolerates about 1e-3 studs off an edge in general; this is the half-grid rounding
    case. The face join keeps Part terrain out of it (seam ends are triangle corners); a
    hand-written description can still hit it. A fix would snap seam ends onto the floor's
    snapped edge.
- **Core 3, open: an obstacle whose corners are under a grid step apart can fold on the grid.**
  - **Repro (case 3):** a convex obstacle with corners (30.00198, 99.99806) and (30.00002,
    100.00004), 0.003 studs apart. Snapped, they swap order: "the ring folds back on itself".
  - The adapter's hull fix keeps Part input out of it; `AddObstacle` with a ring like this
    still fails. A fix would drop corners that snap within a grid step of the last.
- **Core, fixed 2026-10-02: a walker beside a vertex where several floors meet could stall for
  good** (found by ticket 38's city day).
  - **Repro:** `lune run tools/navmesh/bench/follower_vertex_stall.luau` printed Blocked; it now
    prints Arrived.
  - **Cause:** the funnel's radius offset asked each portal's own floors whether its end is a
    wall corner. At (40, -110) six meadow floors meet, and only Meadow6_9a has a wall there: a
    hairline slit from (40, -110) to (45, -115) that the adapter's weld left open. The corridor
    went the long way round the slit's tip, through floors where the vertex is free space, so
    the funnel put a corner waypoint on the tip itself, with the next one (40, -111) across the
    slit. `Advance` reached the tip within the radius on the slit's north side, then walked
    straight at the slit: no slide (the slit is square to the move), the push put it back, and
    a re-plan gave the same funnel. The start snapping onto Meadow6_9a was not the cause.
  - **Fix:** the funnel's wall-corner test turns round the vertex's fan across neighbours and
    seam portals, so a wall on any floor meeting there counts. Spec: "a wall corner where several
    floors meet is rounded at the radius, and arrived past" (NavMesh.Follow).
  - **Cost (ruled 2026-10-02: cache it):** the fan walks alone made `FindPath` with
    `AgentRadius` > 0 on City 12-14% slower. The answers are now cached per mesh by vertex id
    (seam-portal ends too), and `Tiles.Update` drops the cache when it swaps the fresh state in
    (`Funnel.Forget`); a deserialized mesh starts empty. Warm, City r = 1 is back to
    0.99-1.02x of before; a query on an empty cache costs what the uncached fix did (about
    +15%); radius 0 is unchanged (200 queries, in-process A/B/C, median of 20). Spec: "an
    Update that walls or frees a corner where several floors meet changes how paths pass it".
  - Track F's tip (18f42e7) stalled on `city_day.luau` seeds 1 and 8 at this spot and on seed 6
    at a riser (NPC 37 on Riser 42); with this fix all three pass.
  - **Left:** clearance is still per floor, so the search can still pick a narrow seam piece
    next to such a corner (here a 0.05-stud piece of the Meadow5_10a/5_9b seam, 0.05 from the
    tip). The walker passes it; the slit itself is an adapter weld gap.
- **Adapter, open: the step-height rule makes no riser where the upper slab tilts down from the
  step** (ticket 34's `MaxStepHeight`, M1's code; found by ticket 37).
  - **Repro:** `lune run tools/navmesh/bench/riser_lean_repro.luau`: a slab rising from a
    0.5-stud step gets 1 riser and Success; the same slab falling gets 0 and Partial.
  - **Cause:** a tilted block's end face leans with it, so the bottom of the face overhangs the
    lower floor (by thickness x sine of the slope). The rule reads that overhang as a cut in the
    riser's band and drops the edge. Upright stair steps never lean, so the building maps pass.
  - **Workaround in ForestRiver:** its first plateau strip starts past its own lean. A fix in the
    rule would ignore cuts from the upper face's own Part.

## Deferred, only if the user asks
- **Precise `IsPathValid`.** Ticket 22 notes what `Clearance.Refresh` already knows.
- **Opt1's in-place commit for `Update`.** It only matters if the remaining O(T) copy shows up;
  see ticket 22.
- **Out of scope per spec.md:** multithreading, crowd avoidance and async search.
- **Tooling chore:** stylua drift remains in `tools/coverage` (`Engine.luau`,
  `OpenCloudRunner.luau`, `modules_on_rails.luau`, `adapters/Tests/run.luau` and three core
  specs). Format it in a formatting-only commit. Never reformat the engine's test fixtures or
  goldens.

## Known gaps left by Track B (2026-10-01)
None of these are wrong answers today, but each is a place where the mesh is weaker or slower
than it looks. Read them before touching `Search`, `Clearance`, `Tiles` or `Serialize`.
- **Update time grows badly with one huge authored ring.**
  - This predates Track B; old and new code are within noise.
  - A crate near a walkable outline of 2,048 points takes 1.6 s to add at TileSize 8, and 5.0
    s at TileSize 32. At 512 points a remove spent about 270 of 275 ms in
    `Clearance.Refresh`.
  - Measure Refresh's reach rule and the wall-index churn on long rings first. Re-snapping the
    whole ring is the smaller part: about 19 ms for a planar 8,192-point ring, marked
    `ponytail:` in `Tiles.reSnap`, with a per-ring edge index as its upgrade path.
- ~~**Links skip ticket 27's end check.**~~ Closed by E3 (2026-10-01; ticket 27, "Link and seam
  entries"): link landings and link starts in the end triangles are judged with `CutOff` /
  `Separated`, and a seam entry takes the seam's edge as its entry edge. Still optimistic (each
  falls back to the old answer, never a false block):
  - from a triangle entered by an edge, a link's start is reached unchecked (checking it would
    close the triangle to a better entry: the node model's gap below);
  - a seam portal is judged by its whole edge (the corner widths), not by the piece;
  - a link end the agent can't stand at, even pushed off the wall, is cut off from nothing, as
    ticket 27 treats an end. The E3 oracle counts 121 new Successes through such points (of
    206 changes) that its flood can't follow;
  - `CutOff` from a point pushed out of its (thin) triangle answers "not cut off".
- **Clearance doesn't see the other floor's walls at a seam** (found by E3's oracle). Widths and
  barriers read the walls of the triangle's own floor, and a seam edge is open, so an agent
  walking along a seam line squeezes between one floor's props and the other's. On the oracle's
  `props+seam` scene (the props room split into two floors at x = 32) both the old and the new
  search return Success along the seam where the flood (one plane) has no room for the radius.
  Two of E3's Partial-to-Success changes are of this kind.
- **Barrier completeness (ticket 27 is sound, not complete).** It misses:
  - a pocket closed by a loop inside one component;
  - a chain between two edges that cuts a corner off without reaching a vertex;
  - a second barrier when the first one found doesn't hold the end;
  - any barrier ending inside a crossable edge. That one is deliberate: no corridor holds the
    U-turn round it.
  Each miss falls back to the old optimistic answer. The goal-again node id has no spec that
  reaches it (ticket 27's mutation notes); the start-again node is now reached by E3's spec of
  a link start past a floating slab.
- **A Partial or Budget end can still lie past a gap narrower than 2r** (narrowed by Track G).
  - Since Track G, each candidate end is pushed off the walls, then checked with
    `Clearance.CutOff` / `Separated` in the triangle the push lands in. A stranded one is
    skipped for the next best.
  - Two kinds of end still pass:
    - **An end the push leaves inside the pinch itself**, still under r from the walls.
      `CutOff` can't place a point that can't stand, so it answers "not cut off". A stricter
      rule was tried: refuse an end that can't stand clear. It also refused ends in acute
      corners, which the two-pass push can't clear, and dragged them back to the start.
    - **A barrier closed in a neighbouring triangle**: the wall that closes it is more than r
      from the end's triangle. This is ticket 27's "barrier completeness" gap.
  - On the many-slab room (`tools/navmesh/bench/partial_end.luau`), ends a grid flood proves
    unreachable went from 216 of 405 to 90. Partial FindPath there went from 30 to 56-61 us mean.
- **A loaded mesh pays an O(triangles) spike once.** After `Deserialize`, the first `Update`
  or the first `FindPath` with an `AgentRadius` builds the wall index. Bake it, or build it
  lazily per tile, if load-time hitches matter.
- ~~**Link ids are dense in Storage.**~~ Closed by Track E (ticket 30 part 1, 3b4d0d5): Storage
  link records are sparse, and the v3 reader takes increasing ids below the next id.
- **FindPath with a radius costs 15-40 us more,** mostly gathering the walls around the start
  and goal triangles (bench.md, "Ticket 27"). Since E3 the walls and the verdicts are kept per
  triangle and radius (up to 32,768 records per mesh), until the walls change.
- **A radius FindPath on a link-dense mesh pays per link node at a new radius** (E3). Each
  link landing is a node, checked with `CutOff` / `Separated` (7-13 us each, cold). On the
  props room with 1,000 random links, a radius drawn per query costs 17x the pre-E3 FindPath
  (Partial 0.5 to 11 ms); at one radius, remembered, 1.4x. With 100 links: 1.8x and 0.8x
  (ticket 27, "Link and seam entries"). Precompute landing verdicts per agent radius if many
  radii matter.
- **The old-sources oracles need a hand-made copy.** `tools/navmesh/bench/radius_oracle.luau`,
  `findpath_radius_cost.luau` and `findpath_links_cost.luau` compare against
  `lib/navmesh/src_old`, made with
  `git archive <base> lib/navmesh/src`. Keep it out of the tree during coverage runs.
- **Scratch archive:** the old `navmesh-phase0` worktree's untracked `zz_*` probes are in the
  main checkout's gitignored `.bench/navmesh/archive/navmesh-phase0/`.

## Found by Track M3 on the Street map (2026-10-01)
Neither is fixed: Track M3 may not change the core, and its adapter change is limited to the
area-name table.
- **The adapter ignores a Part exactly `AgentHeight` tall standing on a floor.**
  - In `cut`, its top corners sit at exactly `agentHeight`, which the `< agentHeight` test
    leaves out, and no edge strictly crosses that level. So `top` stays 0 and the cut is dropped.
  - Repro: a 10 x 10 ground slab at y 0 and a 2 x h x 2 box on it, default options. h 4.99 and
    5.01 give one obstacle ring, h 5 gives none.
  - Found when the Street's 5-stud cars didn't cut the road: paths and radius 3.5 went straight
    through them. The map uses 4.5-stud cars.
  - **Fix:** count a point at exactly `agentHeight` toward `top` (and the hull), or test
    `<= agentHeight` for the top. Owner: whichever track next changes the adapter.
- **A finite area cost turns heron nodes off for the whole query, even for paths that never
  touch that area.** `Search` keeps heron nodes only when every multiplier is 1 or excluded.
  - On the Street (`lune run tools/navmesh/maps/street_measure.luau`), at road cost 5 or 10
    every path stays off the road, yet it is on average 0.5% and at worst 11.7% longer than the
    best crosswalk-only path (road excluded, heron on). The worst, S52->N44, takes the east
    crosswalk (73.8) instead of the west one (66.1). That is midpoint A* picking the wrong
    crosswalk.
  - At road cost 1.5 to 3 the worst is 7.3-10.7%.
  - This is the trade-off Search's header documents (goal-ward nodes overprice routes round
    dear areas), seen on a realistic layout. A fix would need the heron gate to be finer than
    "any cost but 1". It is not ruled.

## Found by Track H on 1-4 km maps (2026-10-01)
These are numbers on large maps, not wrong answers. Each has a script under
`tools/navmesh/bench/`. Details are in bench.md, "Large worlds, 1-4 km". None is fixed. Track H
changes no library code.
- **Build and Update cost O(triangles x walkable rings) on a floor.**
  - Build's heights loop (`triangulateTile`, "Heights. Each kept triangle...") asks every
    walkable ring's surface for every kept triangle, with one `CDT.Locate` each. `Update` hands
    the same per-floor surface list to `TriangulateTile`.
  - `rings_repro.luau`: on an n x n grid of 8-stud walkable squares, Locates per triangle
    equal the ring count. At 4,096 rings, Build takes 7.4 s and one crate's `Update` 330 ms.
  - A terrain adapter's output hits this. At the default TileSize, the terrain map takes:
    - 3.3 s to Build at 1 km, 63 s at 2 km and 35 minutes at 4 km;
    - 16, 80 and 583 ms per warm `Update`.

    `profile_build.luau 1024 default terrain` puts 80% of the time in `Locate`.
  - **Fix:** give each tile only the surfaces whose box meets it (a tile hash of ring boxes).
  - **Owner:** Track F, which owns Build and the re-snap.
- **Appending with `table.move` is quadratic in Luau.**
  - The append sites: `Storage.SetFloorSources` (every authored ring), `InsertSeam`,
    `InsertObstacleRecord`, and the seam pieces in `Tiles.prepare`.
  - `Deserialize` of the 4 km open map (42k rings) spends 520 of its 731 ms in
    `SetFloorSources`, against 4 ms at 2 km (`deserialize_profile.luau`).
  - `tablemove_repro.luau` shows it in plain Luau: 80k four-point appends take 680-740 ms by
    `table.move`, and 4-5 ms by index.
  - **Fix:** append by index, or `table.create` the destination.
  - Without it, `Deserialize` would run at about 0.9 us per triangle, about 240 ms at 4 km.
- **A warm Update scans every authored ring on its floor.** `Tiles.reSnap` takes the bounds of
  every ring to find those near the dirty tiles.
  - `update_profile.luau`: on the open map, the scan takes 1.5 ms at 1 km, 8.4 ms at 2 km and
    44 ms at 4 km, out of a 67 ms `Update`. The rebuild itself is about 2 ms.
  - **Fix:** a per-floor index of ring boxes, like Snap's tile hash.
  - **Owner:** Track F (the re-snap).
- **Update re-joins every seam (`Build.Internal.Connect`).** It takes 7.2 ms per `Update` on
  the 4 km city's 862 seams and 863 floors (`update_profile.luau city`).
- **The O(T) clean-tile copy now shows** (the Opt1 deferred item above): 5.3 ms at 66k
  triangles and 18.6 ms at 265k.
- **Buffers keep their growth capacity after `Deserialize`.**
  - The triangle buffers are sized to the next power of two, so up to half is slack
    (`heap_fields.luau`: 182 bytes per triangle allocated, where the data needs 92).
  - The 4 km open map holds 66 MB at the default TileSize (265k triangles, capacity 524k) and
    42 MB at TileSize 128 (255k triangles, capacity 262k).
  - **Fix:** size the buffers exactly on load.
- **The load spike, measured** (the item above). On the 4 km open map:
  - the first radius `FindPath` takes 130 ms, against 22 ms warm;
  - the first `Update` takes 250 ms, against 73 ms.

## Found on Highlands' adaptive terrain (Track M2, 2026-10-02)

Highlands moved to `Terrain.Adaptive` (cells 32 down to 2 studs). Each of these failed the
build or slowed it; the map dodges the first three, none is fixed.
- **Adapter, riser seams under the grid:** `riserStrips` keeps an interval longer than 0.001
  studs, below the core's 1/256-stud grid, so Build fails "seam N: has zero length on the
  1/256-stud grid" (the log's riser over a 2-stud terrain cell). The other adapter cutoffs use
  HEIGHT_TOLERANCE (0.01); this one is a one-line change, M1's code, unruled. Dodged: the trail
  ends were moved off the log.
- **Adapter, fans fold rings:** terrain stitched with fans (a cell's middle joined to its
  smaller neighbours' corners) joins into walkable rings that run out to a vertex and back, and
  Build rejects "the ring folds back on itself". Repro: `tools/navmesh/bench/adaptive_fan_repro.luau`
  (snap stitching builds, fan fails). A small fan alone builds; it needs Highlands' cuts too.
- **Adapter, risers on tilted outcrops:** random tilted rocks (outcrop seeds 4242, 4246) fail
  Build "floors 'Riser N' and 'Outcrop M' don't meet across it": a 0.18-stud riser onto a tilted
  face that other cuts crowd. Dodged: seed 4245.
- **Core, Build uncapped:** without `MaxAgentRadius`, Build on a 64 x 64 adaptive patch
  (215 floors, 356 seams) ran over two minutes; with 2, 0.2 s. The docs say "30-50% more".
- **Core, GenerateLinks cost:** 42 s on Highlands (10,665 triangles, 329 links), against 12 s
  FromParts and 4 s Build: the detour walk per candidate. Studio can't run it inside its
  10-second "not responding" watchdog, so big maps bake in Lune (`maps/bake.luau`).
