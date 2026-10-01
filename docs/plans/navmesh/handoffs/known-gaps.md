# NavMesh known gaps and deferred items (2026-10-01)

Read this before touching `Search`, `Clearance`, `Tiles` or `Serialize`. Each item names the
track that now owns it, where one does. Items without an owner are deferred until the user asks.

**Owned by a round-2 track:**
- **Links skip ticket 27's end check, and Storage link ids are dense:** Track E.
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
- **Links skip ticket 27's end check.**
  - A link that lands in the goal triangle, or starts in the start triangle, doesn't check that
    the agent can get between the link point and the end. Barriers are only checked across
    edges and seam portals.
  - Leaving a triangle entered by a link or a seam reads the exit edge's portal width only, as
    the start did before ticket 27; the landing point itself is never checked.
  - Ticket 30 (runtime and generated links, on `research/roblox-pathfinding`) will make links
    far more common, so fold this in there.
- **Barrier completeness (ticket 27 is sound, not complete).** It misses:
  - a pocket closed by a loop inside one component;
  - a chain between two edges that cuts a corner off without reaching a vertex;
  - a second barrier when the first one found doesn't hold the end;
  - any barrier ending inside a crossable edge. That one is deliberate: no corridor holds the
    U-turn round it.
  Each miss falls back to the old optimistic answer. The search's start-again and goal-again
  node ids have no spec that reaches them; no mesh built so far needs them (ticket 27's
  mutation notes).
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
- **Link ids are dense in Storage.** v3 bakes carry link ids and a next id, but the reader
  still requires ids 1..n. Ticket 30's sparse ids need Storage link ids first, then this
  reader check relaxed. The format itself needs no change.
- **FindPath with a radius costs 15-40 us more,** mostly gathering the walls around the start
  and goal triangles (bench.md, "Ticket 27"). The last answer is memoized per mesh. Cache per
  triangle if radius queries get hot.
- **The old-sources oracles need a hand-made copy.** `tools/navmesh/bench/radius_oracle.luau`
  and `findpath_radius_cost.luau` compare against `lib/navmesh/src_old`, made with
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
