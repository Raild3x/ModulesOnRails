# Track D: later work (blocked until A or C lands)

Read [README.md](README.md) first. None of this should start until its blocker has merged. Each
item touches files that Tracks A and C are changing.

## D1. Geometry simplification (after Track C's adapter)
- **The plan:** `docs/plans/navmesh/simplification-plan.md`. It is measured, and it has user
  rulings.
- **Build both recommended passes:**
  - **R1, one-sided ring simplification:** the collinear-merge idea, with a distance tolerance
    in studs.
    - Walkable rings only shrink and obstacles only grow, checked exactly with `Orient2D` on
      grid integers.
    - It also collapses edges by extension, which convex rings such as cylinders need.
  - **R2, exact dissolve of same-class constraint edges:** triangles on both sides of an edge
    share the same area and height plane, so no geometry moves.
- **Rulings (2026-09-28):**
  - build both, after the Part adapter;
  - one mesh-wide `NavMeshDesc.SimplifyTolerance` that users can override (0 turns it off);
  - the user suggested **1/10 stud as the default**, so measure it against the plan's 1/16 and
    1/4 before finalizing;
  - crack welding stays in the adapter.
- **Prototypes:**
  - branch `proto/simplify`, worktree `simplify-proto`: `quantizeRing` P1 and the per-tile
    dissolve;
  - its probe scripts sit untracked at that worktree's root;
  - results and scenes (`rocks`, `pieces`) are in gitignored `.bench/simplify/` there.
- **The epsilon must be stored in the bake,** so `AddObstacle` after `Deserialize` simplifies
  alike. Coordinate the format with Track B's v3.
- **Gate:** the guarantees G1-G8 from the plan as specs, with "Update equals a fresh Build"
  kept. Replace the two specs the plan says the ring pass legitimately changes with their
  one-sided versions.

## D2. Ticket 25: path shape and waypoint metadata (after Track A's ticket 23)
- waypoints where a path crosses a seam or a crease: repro 7, where interpolating Y lands under
  an overhang;
- no bends at equal-cost area boundaries. The simplification study found per-path length
  swings of 0.8x-1.29x from search-node placement, not only at area edges, so re-measure before
  choosing a fix;
- a link id on the link's waypoint, an optional `LinkDesc.Name`, and `SetLinkEnabled` by name;
- whether `PathResult` gets a `Length`;
- **an optional bisector-offset funnel.** The funnel's real guarantee is weak: straight stretches
  can pass within 0.06r of a wall on dense maps, as documented in `Funnel.luau` and
  `QueryFilter.AgentRadius`.

## D3. Deferred, and only if the user asks
- **Precise `IsPathValid`.** Ticket 22 notes what `Clearance.Refresh` already knows.
- **Opt1's in-place commit for `Update`.** It only matters if the remaining O(T) copy shows up;
  see ticket 22.
- **Out of scope per spec.md:** multithreading, crowd avoidance and async search.
- **Tooling chore:** stylua drift remains in `tools/coverage` (`Engine.luau`,
  `OpenCloudRunner.luau`, `modules_on_rails.luau`, `adapters/Tests/run.luau` and three core
  specs). Format it in a formatting-only commit. Never reformat the engine's test fixtures or
  goldens.

## D4. Known gaps left by Track B (2026-10-01), not yet ticketed
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
- **A Partial path's end ignores the radius inside its last triangle.**
  - The end is that triangle's point nearest the goal, then pushed off the walls (ticket 24).
    It can still lie past a gap narrower than 2r inside that triangle.
  - Only the start triangle is guarded, once a barrier cut the start off.
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
