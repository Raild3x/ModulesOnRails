# 28: Which part of a path a change blocked

**What to build:** A pure helper that tells a game whether an `Update` affected the rest of a
path, and where, so it re-paths only the NPCs whose way ahead changed.

**Blocked by:** none (ticket 22's `ChangedRegion` and ticket 23's follower are merged)

**Status:** built on `navmesh-path-output` (2026-10-01, Track G). Ruled 2026-09-28 (review.md, D4: "Helper now, the rest with
multithreading"). From
[research/roblox-pathfinding-comparison.md](../research/roblox-pathfinding-comparison.md)
gap G2, and the dogfood report's pain point 4.

- [x] `NavMesh.FirstAffectedSegment(path, regions, radius, fromSegment?) -> number?`
  - `path` is a `PathResult`; `regions` is what `Update` returned; `radius` is the agent's
    `AgentRadius`.
  - It returns the index `i` of the first segment `Waypoints[i] -> Waypoints[i + 1]`, at or
    after `fromSegment` (default 1), that meets a region box on its floor, with the segment
    fattened by `radius`. It returns `nil` when none does.
  - It is plain functions over plain data. There is no Signal or object (N1/V4).
- [x] **Cheap reject first:** test the path's plan bounding box (from `fromSegment` on, grown by
      `radius`) against each box. Only on a hit test the segments. That skips far-away paths
      in O(regions).
- [x] **Floors:** a segment is tested against the boxes of both its end waypoints' floors,
      since a seam crossing changes `Floor` between waypoints. Region Y is ignored, because
      regions are per floor already.
- [x] **Link segments** (the waypoint has a `Label`) have no walkable geometry between their
      ends, so only the two end points are tested (fattened by `radius`).
- [x] **With the follower:** document `FirstAffectedSegment(follower.Path, regions, r,
      follower.Next - 1)`. Roblox's guide rule, "re-path only if the block is ahead of the
      agent", then comes for free.
- [x] **Property spec (ticket 22's contract):** over seeded random paths and random obstacle
      *adds*, whenever the helper returns `nil`, `FindPath` after the `Update` returns the same
      waypoints. Adds only, because a removal can open a better route through a box, which
      the contract excludes.
- [x] **Demo:** replace `Game.luau`'s `revalidate` polling. Report the repaths per door toggle
      against today's (the report had 119 repaths for 19 toggles).
- [x] Negative controls: dropping the radius fattening, the floor check, or the prefilter's
      grow each fail a spec.

## Not in this ticket
- `ApplyOps` (replaying plain change records per Actor) and an Actor-local `Changed` Signal
  module. They wait for the multithreading work (review.md D4). The research doc's "D4 debate"
  section holds the design.

## As built (2026-10-01, Track G)
- **`NavMesh.FirstAffectedSegment(path, regions, radius, fromSegment?) -> number?`** in
  `NavMesh.luau`, as specified. Arguments are checked at the call, like `NewFollower`.
  - The radius grows each box into a square, the same slab test the Obstacles spec and the
    demo bench had hand-rolled. It never misses where the round agent meets a box, and can
    over-report by up to 0.41 r at a box corner.
  - A one-waypoint path is its point, as segment 1. Past the last segment it returns nil.
  - A link segment is any segment from a waypoint with a `Label`. An unlabelled link has no
    label, so it is tested as a whole segment: conservative. Track E's link id on the
    waypoint can tighten that.
- **Specs:** `NavMesh.Affected.spec.luau` (8 tests). The property test runs 6 random adds over
  two floors joined by a ramp, with paths at r 0 and 0.4. The Obstacles spec's ticket-22
  property test, which also covers removals, now calls the helper instead of its own copy,
  and so does the demo's `bench.luau`.
- **Negative controls:** each fails a spec: no radius fattening (3 fail), no floor check (1),
  testing only the first end's floor (1), no prefilter grow (2), link segments tested as whole
  segments (1). The prefilter itself is only a speed reject, so dropping it, or starting its
  bounds at waypoint 1, fails nothing. Those two mutants are equivalent.
- **Demo:** `Game.luau`'s door toggle calls `repathAffected`, which uses
  `FirstAffectedSegment(follower.Path, regions, npc.Radius, follower.Next - 1)`. The gate toggle
  still polls `IsPathValid`, because `SetLinkEnabled` returns no regions.
  - **Repaths from door toggles, 120 s sim, seed 7, 19 toggles** (old = `IsPathValid` polling):

    | TileSize | old | new | new per toggle |
    |---|---|---|---|
    | default (one tile per floor) | 118 | 121 | 6.4 |
    | 16 | 77 | 72 | 3.8 |
    | 8 | 75 | 59 | 3.1 |
    | 4 | 64 | 44 | 2.3 |

  - The first report counted 119; today's polling counts 118.
  - **At the demo's default TileSize the helper saves nothing.** Each floor is one tile, and a
    region holds whole rebuilt tiles, so every region is the whole floor. The door is also the
    only ground passage between the two rooms, so many paths really do cross it.
  - **A tighter region was prototyped and rejected.** It boxed only the rebuilt triangles that
    don't match an old one by grid key, plus the re-widthed ones. All 279 specs passed, including
    ticket 22's oracle. But the demo only went from 121 to 100 at the default TileSize, and was
    unchanged at 16, 8 and 4: the level's triangles are room-sized. It would change `Tiles`,
    which this track doesn't own. Smaller tiles are the lever, so the `Update` doc now says so.
  - The check costs 1.5-2.6 us per NPC per toggle, against 0.4-0.9 us for `IsPathValid`.
