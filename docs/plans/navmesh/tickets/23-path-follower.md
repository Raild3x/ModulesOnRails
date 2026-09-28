# 23: Path follower

**What to build:** An optional helper that moves an agent along a `PathResult`, so every game
doesn't hand-roll about 150 lines with the same traps.

**Blocked by:** none (it uses the public API only)

**Status:** built on `navmesh-ticket23` (2026-09-28), API shape B (review.md, 2026-09-28).
From the dogfood report, pain point 3.

- [x] It advances by `maxStep` per call along the waypoints, using `MoveAlongSurface` for the
      walkable segments
- [x] **Arrival:** it treats the radius-pushed stop as arrived *(ends are offset since ticket
      24; corner waypoints still need a radius tolerance, now inside `Advance`)*
- [x] **Links:** on a `Label` waypoint it emits a link event (label, from, to) and does not
      walk the segment to the landing
- [x] **Blocked:** it reports the agent as blocked when progress stalls or the agent is left
      off the mesh (a door closed on it). It never throws.
- [x] A spec drives the trap cases: a `Partial` end on a wall face, a corner inside the radius,
      the jump link, and a door closing on the agent *(on the library fixtures, not the demo
      level, which lives outside the package)*

## API (ruled 2026-09-28: shape B)
- `NavMesh.NewFollower(path, stallSteps?) -> Follower`: plain data `{ Path, Next, Stalled,
  StallSteps, Link }`. `stallSteps` defaults to 10.
- `NavMesh.Advance(mesh, follower, position, maxStep, filter) -> (position, floor, event)`,
  where `event` is `nil | "Arrived" | "Link" | "Blocked"`. It updates `follower` in place.
- The rejected shape A was the ticket sketch, `Advance(mesh, path, cursor, position, maxStep,
  filter) -> (position, floor, cursor, event)`. Prototyped on `Game.luau` over the same core,
  both gave identical sim counters (0 stuck, 12 jumps). `follow` was 39 lines with B and 55
  with A, since A left the stall timer and the link-endpoint arithmetic to the game.

## As built (2026-09-28, branch `navmesh-ticket23`)
- **Arrival:** a waypoint is reached when the step ends within `AgentRadius` (+ 0.01 of f32
  rounding) of it, and either the step covered the distance or the agent stalled. The funnel
  puts corner waypoints on the portal, nearer a wall than the radius (SR4), so
  `MoveAlongSurface`'s push stops short of them. The corner spec stalls without this, even
  after ticket 24.
  - "Covered the distance" alone, the demo's old rule, is wrong. An agent stopped by a new
    wall one stud short of a waypoint, with a step of 1 or more, counted as arrived. The spec
    now drives that case.
  - Measured on 3,500 random walks (every fixture, r 0 to 1): the ruled r·√2 + 0.05 bought
    nothing over r, and dropping the guard (arriving whenever within r) cut corners (119
    failures), so both went.
- **Links:** the check sits at the top of `Advance`. When the waypoint the agent stands at
  has a `Label`, it returns `"Link"` without moving, sets `follower.Link = { Label, From, To }`
  and moves the cursor past the landing. A path that starts on a link emits it at once.
- **Blocked:** a step that moves under 10% of `maxStep` counts as a stall, and progress resets
  the count. Off the mesh (`MoveAlongSurface` `NoStart`) it is `Blocked` at once, with no
  floor. `floor` is nil only then, or for a path with no waypoints.
- **Core fix found by the follower's property check: walking from a wall corner.** At radius 0
  the funnel puts waypoints exactly on wall vertices. `Queries.Walk` started in whichever fan
  triangle the snap chose. When the direction lay outside that triangle's corner, the walk hit
  the corner's wall at distance 0, so `MoveAlongSurface` and `Raycast` from (11, 5) on the
  Courtyard crate went nowhere, even heading into open ground. Now `fanStart` turns around the
  vertex, one way and then the other (a fan on a wall is open on one side only), to the
  triangle whose corner holds the direction. The spec sweeps 16 directions from two crate
  corners.
- **Core fix 2 (ticket 24's end offset): wall normals under f32 rounding.**
  - `vector` is f32, so for a point on or a hair off a wall, `DistanceToWall`'s foot point
    lands up to 2.4e-7 *along* the wall. The normal `p - q` then pointed along the wall.
  - On OneWayLink (r = 0.25), `FindPath`'s end push slid a `Partial` end 0.5 along the wall
    and left it on it.
  - Now, when the nearest point is inside the edge, the normal is the edge's own inward normal,
    which is exact. Only an end vertex uses `p - q`. The specs cover both cases, and the
    stress walks' two remaining failures on ShallowObstacles went with it.
- **Robustness:** 3,500 random walks (7 fixtures × 500, r 0 / 0.25 / 0.5 / 1, three step
  sizes, links hopped) all arrive with stall steps set to 1.
- **Demo:** `Game.luau` −44 lines (32 added, 76 removed). `follow` went from 79 lines to 41,
  of which 18 are the game's own jump animation. The hand-rolled parts are gone: the waypoint
  cursor, the link detection, the corner arrival tolerance, the stall timer and the off-mesh
  branch. `StudioDemo.luau` draws from `follower.Path`. Sim (seed 7, 120 s): 0 stuck, 12
  jumps, the same repath counts as the prototypes. `Advance` costs 7.9 µs mean, against 7.1
  µs for the bare `MoveAlongSurface` call.
- **Negative controls:** each fails the suite when reverted:
  - `fanStart` (2 specs), and each of its edge choices and its boundary test;
  - the corner tolerance, the arrive-only-when-reached guard, the default radius for a nil or
    empty filter, and a paused frame (`maxStep` 0) never stalling;
  - the link check (2), the stall debounce (2), the immediate off-mesh `Blocked` (1), and the
    stall reset (1);
  - the edge normal, and the vertex normal off a corner.
- **Gate:** 252/252 specs, 98.9% lines.
- **Mutation** (`--mutate-files=src/NavMesh.luau,src/Queries.luau`): Queries 232/282 (82.3%,
  was 80.9%). NavMesh 175/185 (94.6%, was 98.2%): the new code added equivalent survivors, and
  no kills were lost.
  - **Equivalent:** the error levels of the new argument checks; `< math.huge` against `<=`
    (`math.huge % 1` is NaN, so it's rejected either way); `remaining <= maxStep` against `<`
    (the step target is the waypoint either way); `fanStart`'s loop starts (0 behaves as side 2,
    and both sides still run); swapping the sides.
  - **Not killed:** the 0.01 f32 allowance (no spec builds a rounding miss); `Stalled = 0` on
    arrival (a stall right after reaching a waypoint would count one step early); the edge
    normal at exactly `k` 0 or 1.

## Related
- **Out of scope:** crowd avoidance and separation (spec).
