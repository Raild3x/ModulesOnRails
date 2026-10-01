# 24: Off-mesh policy and closest-reachable queries

**What to build:** One consistent answer when a position is off the mesh, and queries that
find the closest usable point.

**Blocked by:** none

**Status:** built on `navmesh-ticket24` (2026-09-28), all five rulings (review.md, 2026-09-28).
From the dogfood report, pain points 5 and 7; repros 3 and 5.

- [x] **One documented off-mesh policy.** Before this ticket, five queries did five things for
      an agent a door closed on:

      | Query | Before | After |
      |---|---|---|
      | `FindPath` | NoStart | NoStart |
      | `FindNearestPoint` | nil | nil; with a search radius, the nearest floor |
      | `Raycast` | blocked at `from` | blocked at `from` |
      | `FindDistanceToWall` | 0 | 0 |
      | `MoveAlongSurface` | throws | `Status` `"NoStart"` |

      The table is in the `NavMesh` class doc.
- [x] `FindNearestPoint` gains a search radius: the closest point however far, bounded by the
      radius
- [x] A `FindPath` option snaps an unreachable or off-mesh goal to the closest reachable
      point, instead of returning `NoGoal` *(`QueryFilter.GoalFallback`)*
- [x] `FindRandomPoint` honours `AgentRadius` *(repro 3: 0 of 1,000 points closer than r=2 to
      a wall, was 652)*
- [x] `FindPath`'s end point is offset by `AgentRadius` *(ruled yes)*
- [x] `FindRandomPoint` takes an options table in place of five positional arguments

## As built (2026-09-28, branch `navmesh-ticket24`)
- **End offset:** `FindPath` runs the last waypoint through `Queries.Push`, the push
  `MoveAlongSurface` already did (split out of `Queries.Move`). It applies to Success, Partial
  and Budget; the pushed end's tile joins `TileStamps`. At radius 0 it is a no-op.
- **`MoveAlongSurface`** returns `MoveResult { Status, Position, Floor? }`, `Status`
  `"Success" | "NoStart"`. Why this shape: it is `FindPath`'s rule (a status field, the same
  `NoStart` name, no location on `NoStart`), so a follower handles both the same way. `Raycast`,
  `FindDistanceToWall` and `FindNearestPoint` already gave a sensible answer and are unchanged.
- **`FindNearestPoint(mesh, position, filter, searchRadius?)`:** when the normal snap misses,
  `Snap.Nearest` scans the triangles within `searchRadius` in plan, with no vertical limit, and
  keeps the one nearest in 3D. A radius wider than the mesh scans the tile list, not every hash
  cell of the box.
- **`FindRandomPoint(mesh, { Filter, Center, Radius, Rng })`:** unknown keys error (a
  `QueryFilter` passed straight in is the likely mistake). At r > 0 it samples only triangles
  with an edge of portal width >= 2r, draws up to 32 points and keeps the first at least r from
  every wall; if all miss, it pushes the last and keeps it only if it then qualifies. Biases are
  in the doc: triangles with no wide-enough edge are skipped, and the push fallback lands on
  the region's edge.
- **`GoalFallback`:** an off-mesh goal runs the search with no goal triangle, so it covers the
  reachable region (up to `MaxExpansions`) and ends `Partial` at the point nearest the goal in
  3D, then end-offset. Status `Partial` is how the caller tells the goal moved.
- **Demo:** `Game.luau` lost 31 lines net (51 removed, 20 added): the `pcall` around
  `MoveAlongSurface`, `pickWanderGoal`'s 8-try wall-rejection loop, the bigger-`SnapExtents`
  rescue and the `NoGoal` branch.
  - **Kept, on purpose: the arrival tolerance.** Removing it gives 6 `stuck` events in `sim.luau`
    (seed 7), all at *mid-path* corner waypoints (for example waypoint 2 of 3), none at an end.
    The funnel places corner waypoints along the portal (SR4), which can be closer than r to a
    wall, so `MoveAlongSurface` stops short of them. Ends no longer need it. Ticket 23's follower
    owns this.
- **Negative controls:** reverting each piece fails the suite: the end push (5 specs), the
  `MoveAlongSurface` status (2), the random-point fit check (5), the portal-width filter (1),
  the search-radius fallback (6), `GoalFallback` (6).
- **Gate:** 236/236 specs, 98.8% lines.
- **Mutation** (`--mutate-files=src/NavMesh.luau,src/Queries.luau,src/Snap.luau`, 541 run):
  NavMesh 112/114 (98.2%, was 99.0%), Queries 195/241 (80.9%, was 81.4%), Snap 165/186 after
  the added spec (88.7%, was 89.7%). The drops are new equivalent mutants, not lost kills:
  - **Killed by a new spec:** `Snap.Nearest`'s `(h - py)` to `(h + py)`, which survived because
    every query sat at y 0 (the deck spec now also asks from y 4).
  - **Equivalent:** the error level of the `GoalFallback` check; `Push` at radius 0 or with a
    third pass; `width > 0` against `>= 0` / `> 1` (the fit check still rejects); the area
    and triangle ids returned beside a nil point; the `* 0.5` in the area total (it scales the
    cumulative table too); the `eachTriangle` wide-box switch (both branches scan a superset of
    the box's triangles, so it only changes cost); `<` against `<=` ties in `Snap.Nearest`.
  - **Not killed:** `FIT` 1e-6 to 0 in `RandomPoint`: a pushed fallback landing within 1e-6
    under r. No spec constructs one.
  - The other survivors are on lines this ticket didn't change.
