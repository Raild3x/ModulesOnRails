# Track A: finish ticket 24, then build ticket 23

Read [README.md](README.md) first for the house rules and the parallel map.

## 1. Ticket 24: off-mesh policy and closest-reachable queries (in progress)

**Where:**
- Branch `navmesh-ticket24`, worktree `C:\Users\Logan\Documents\GitHub\TableManager\.claude\worktrees\ticket24`.
- Its commit 15d0c4c is the previous agent's WIP. That agent was cut off by a usage limit. The WIP
  contains:
  - a new `NavMesh.Reachable.spec.luau` (407 lines);
  - partial changes to NavMesh, Queries, Snap, Search and Types;
  - the demo's `Game.luau`, `repros.luau` and `bench.luau` moved to the new APIs.
- Nothing in it is gated. Treat it as a draft: read it, keep what's right, and fix the rest.

**First:** merge `feat/navmesh` into the branch. The WIP predates ticket 22, which changed
Tiles, Clearance, Storage and Snap (`Snap.TilesIn`), and `Update` now returns changed regions.
Resolve conflicts, then run `lune run tools/navmesh/specs.luau` to see where the draft stands.

**The user's rulings (2026-09-28). All are required; don't reopen them.**
1. **End-point offset.** `FindPath` pushes a path's last waypoint to the nearest point at least
   `AgentRadius` from the walls, using the same push `MoveAlongSurface` uses.
   - It applies to Success, Partial and Budget ends.
   - At radius 0 the end is unchanged.
   - Document that the end can differ from the requested goal by up to the radius.
2. **`MoveAlongSurface` no longer throws on off-mesh input.** It returns a status instead.
   - Choose a shape consistent with `FindPath`'s `NoStart`, and justify it.
   - Write one documented off-mesh policy for all the queries, in the `NavMesh` class doc.
   - Today, for an agent in a closed doorway: `Raycast` reports blocked at `from`,
     `FindDistanceToWall` returns 0, and `FindNearestPoint` returns nil. Keep whatever is
     already a sensible status.
3. **`FindRandomPoint(mesh, { Filter, Center, Radius, Rng })`,** an options table replacing the
   5 positional arguments.
   - It honours `Filter.AgentRadius`: it samples only where a radius-r agent fits, then pushes
     the point off the walls.
   - State any sampling bias in the docs.
4. **`FindNearestPoint` takes an optional search radius:** the closest point within that plan
   distance, however far outside `SnapExtents`. Its cost is bounded by the radius.
5. **`FindPath` goal fallback:** an option that snaps an unreachable or off-mesh goal to the
   closest reachable point instead of returning `NoGoal`.
   - The caller must be able to tell the goal moved.
   - Define "closest reachable" precisely (plan or 3D, and the search bound) and document it.

**Also:**
- Delete the demo's hand-rolled workarounds that the library now covers: the arrival tolerance,
  `pickWanderGoal`'s rejection loop, and `repath`'s bigger-`SnapExtents` retry. Report how many
  lines went away.
- Re-run `lune run examples/navmesh-demo/repros.luau` (repros 3 and 5) and
  `lune run examples/navmesh-demo/sim.luau`.

**Gates:**
- Specs first, each with a negative control.
- Property checks over many seeds:
  - every returned path end is at least r from the walls, within the snap wobble;
  - `FindRandomPoint` with r > 0 never returns a point within r of a wall;
  - the goal fallback never returns a point that `FindPath` can't then reach.
- The full gate, and a mutation gate on the changed `src` files.
- stylua clean.

**Docs:** record the rulings in `review.md`, add as-built notes to ticket 24, and update the API
docs and `CONTEXT.md`. Then merge into `feat/navmesh`.

**Source material:**
- tickets 24 and 23;
- `examples/navmesh-demo/REPORT.md`, pain points 3, 5 and 7;
- `Game.luau`'s `follow`, `repath` and `pickWanderGoal`.

## 2. Ticket 23: path follower (after 24 is merged)

**What:** an optional helper that moves an agent along a `PathResult`, with arrival, link events
and blocked detection, so games stop hand-rolling about 150 lines. See
`docs/plans/navmesh/tickets/23-path-follower.md`.

**Needs a user ruling before building: the API shape.**
- Ticket sketch:
  `NavMesh.Advance(mesh, path, cursor, position, maxStep, filter) -> (position, floor, cursor, event)`
  - `event` is `nil | "Arrived" | "Link" | "Blocked"`.
  - It is plain functions over plain data, like the rest of the API, with no agent object.
- Offer this against an alternative (for example a small follower-state table), with pros and
  cons. Prototype both on the demo's `Game.luau` before asking, and show the line counts.

**Now easy thanks to 24:**
- Arrival is a plain distance check, because ends are offset.
- `MoveAlongSurface` returns a status, so there's no pcall.

**Still needed:**
- **Link segments:** emit `Link` with the label; never walk the segment to the landing.
- **Stuck and blocked detection:** no progress, or knocked off the mesh.

**Gates:** as in 24. Rewrite `Game.luau`'s `follow` on the helper and report the lines removed.
