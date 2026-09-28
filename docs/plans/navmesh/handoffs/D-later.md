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
