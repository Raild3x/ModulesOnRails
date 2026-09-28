# 28: Which part of a path a change blocked

**What to build:** A pure helper that tells a game whether an `Update` affected the rest of a
path, and where, so it re-paths only the NPCs whose way ahead changed.

**Blocked by:** none (ticket 22's `ChangedRegion` and ticket 23's follower are merged)

**Status:** needs-triage. Ruled 2026-09-28 (review.md, D4: "Helper now, the rest with
multithreading"). From
[research/roblox-pathfinding-comparison.md](../research/roblox-pathfinding-comparison.md)
gap G2, and the dogfood report's pain point 4.

- [ ] `NavMesh.FirstAffectedSegment(path, regions, radius, fromSegment?) -> number?`
  - `path` is a `PathResult`; `regions` is what `Update` returned; `radius` is the agent's
    `AgentRadius`.
  - It returns the index `i` of the first segment `Waypoints[i] -> Waypoints[i + 1]`, at or
    after `fromSegment` (default 1), that meets a region box on its floor, with the segment
    fattened by `radius`. It returns `nil` when none does.
  - It is plain functions over plain data. There is no Signal or object (N1/V4).
- [ ] **Cheap reject first:** test the path's plan bounding box (from `fromSegment` on, grown by
      `radius`) against each box. Only on a hit test the segments. That skips far-away paths
      in O(regions).
- [ ] **Floors:** a segment is tested against the boxes of both its end waypoints' floors,
      since a seam crossing changes `Floor` between waypoints. Region Y is ignored, because
      regions are per floor already.
- [ ] **Link segments** (the waypoint has a `Label`) have no walkable geometry between their
      ends, so only the two end points are tested (fattened by `radius`).
- [ ] **With the follower:** document `FirstAffectedSegment(follower.Path, regions, r,
      follower.Next - 1)`. Roblox's guide rule, "re-path only if the block is ahead of the
      agent", then comes for free.
- [ ] **Property spec (ticket 22's contract):** over seeded random paths and random obstacle
      *adds*, whenever the helper returns `nil`, `FindPath` after the `Update` returns the same
      waypoints. Adds only, because a removal can open a better route through a box, which
      the contract excludes.
- [ ] **Demo:** replace `Game.luau`'s `revalidate` polling. Report the repaths per door toggle
      against today's (the report had 119 repaths for 19 toggles).
- [ ] Negative controls: dropping the radius fattening, the floor check, or the prefilter's
      grow each fail a spec.

## Not in this ticket
- `ApplyOps` (replaying plain change records per Actor) and an Actor-local `Changed` Signal
  module. They wait for the multithreading work (review.md D4). The research doc's "D4 debate"
  section holds the design.
