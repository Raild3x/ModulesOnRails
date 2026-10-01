# Track G: path output (round 2, order 1)

Read [README.md](README.md) first for the house rules and the order. This track runs beside
Track H, which touches no library code. Merge G before Track E starts.

**Setup:** a worktree off `feat/navmesh`, branch `navmesh-path-output`.

## G1. Ticket 28: `FirstAffectedSegment` (small; do it first)
- The full spec is in `docs/plans/navmesh/tickets/28-blocked-ahead.md`. It was ruled in
  review.md, research D4: "Helper now, the rest with multithreading".
- **The function:**
  - It is a pure helper over plain data, with no Signal and no object.
  - It reads the `ChangedRegion` list that `Update` returns (ticket 22).
  - It takes a `fromSegment` for use with the follower (ticket 23).
- **Out of scope:** `ApplyOps` and Actor-local Signals wait for the multithreading work.
- **Demo:** replace `examples/navmesh-demo/Game.luau`'s `revalidate` polling. Report the repaths
  per door toggle against the first dogfood report's 119 repaths for 19 toggles.

## G2. Ticket 25, except its link items (Track E owns those)
The full spec is in `docs/plans/navmesh/tickets/25-path-shape.md`.
- **Waypoints where a path crosses a seam or a crease** (a slope change).
  - Repro 7 in `examples/navmesh-demo/repros.luau`: interpolating Y between waypoints lands
    under an overhang.
  - Check how the follower (ticket 23) consumes them.
  - The alternative is a `SamplePath` helper. If both are viable, present both to the user with
    numbers.
- **The area-edge bend: measure before fixing.**
  - Repro 4 shows +8% at an equal-cost area edge.
  - The simplification study found per-path length swings of 0.8x-1.29x from search-node
    placement in general, not only at area edges (`simplification-plan.md`, R3).
  - Measure the length distribution against a reference: a visibility-graph shortest path on
    small scenes, for example.
  - If a fix (a shortcut pass over equal-cost segments, or another node placement) changes
    `Search.luau` or the node model, it's an architecture fork. Present options with numbers.
- **`PathResult.Length`:** whether to add it (`Cost` is the search cost, not the polyline
  length). This is a small API addition; ask only if there is a real trade-off.
- **An optional bisector-offset funnel.** Today straight stretches can pass within 0.06r of a
  wall on dense maps (the `Funnel.luau` doc and `QueryFilter.AgentRadius`).
  - Prototype it and measure clearance and path length on the bench maps.
  - Then present: keep the current funnel, an opt-in bisector funnel, or replace it.
- **Not yours (Track E):** the link id on a link's waypoint, `LinkDesc.Name`, and
  `SetLinkEnabled` by name.

## G3. A Partial path's end ignores the radius inside its last triangle
- See [known-gaps.md](known-gaps.md).
- The end is that triangle's point nearest the goal, pushed off the walls (ticket 24). It can
  still lie past a gap narrower than 2r inside the triangle.
- Reuse ticket 27's barrier code (`Clearance.CutOff` / `Separated`). Don't add a second
  mechanism.

## Gates
- Specs first, each with a negative control.
- Mutation on Funnel, NavMesh and any other changed file, at or above its baseline in
  `docs/plans/navmesh/mutation-baseline.md`.
- stylua clean. Update the tickets' as-built notes, review.md and CONTEXT.md.
- Merge into `feat/navmesh`.
