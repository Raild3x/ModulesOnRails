# 32: A funnel that keeps the agent's radius at corners

**What to build:** A funnel whose path keeps `AgentRadius` from wall corners at turns, so paths
stop hugging corners on dense maps.

**Blocked by:** none. Ticket 25's measurements (Track G) are its starting point.

**Status:** needs-triage. Ruled 2026-10-01 (review.md, Track G): "Create a new ticket for this,
in the meantime keep it as is today".

**Today:** each wall-vertex portal end moves r along its portal. Over random paths the worst
clearance is 0.06-0.24 r on the bench `walls` scene and 0.01-0.08 r on the dense `bench` map.
In 79-100% of paths the worst point is within 1.5 r of a turn waypoint, not on a straight
stretch. An NPC doesn't clip, because `MoveAlongSurface` pushes it off the walls, but it hugs
corners.

**What was ruled out (ticket 25, branch `proto/g-bisector`,
`docs/plans/navmesh/research/bisector-funnel.md` there):**
- **Moving a portal end off its edge** (bisector, arc, r/sin offsets) bends the corridor. 0.7-8%
  of dense-map paths cross a wall.
- **A post-check** makes that safe, but it falls back to today's path for 10-47% of dense-map
  paths, which leaves the worst case where it was. FindPath gets 1.6-2.3x slower.
- **On-portal variants are safe but barely help.** `sine` takes `walls` from 0.06 to 0.10 r.

- [ ] **A radius-aware funnel:** portals stay on their edges, and each wall corner is an
      r-circle that the string wraps (Demyen's tangent funnel, or an equivalent). This
      rewrites `pull`, not `push`. Turns become arcs, emitted as one or more waypoints.
- [ ] **The yardstick:** `tools/navmesh/bench/funnel_clearance.luau` (on `proto/g-bisector`). It
      takes the exact distance to every wall edge, with a negative control that reproduces
      0.06 r. Report clearance min/p5/p50, path length against today, and FindPath time, on
      `walls`, Courtyard, `bench` and `props` at r 0.5, 1 and 2.
- [ ] **A dense-map spec** with a negative control. Today's specs only use small sparse
      fixtures, and none of them caught the prototype's wall crossings.
- [ ] **Exact clearance check, if needed:** the closest approach between two segments is at an
      endpoint of one of them. So a path is at least r clear exactly when every waypoint is at
      least r from the walls, and every segment is at least r from every nearby wall vertex.
- [ ] Keep ticket 25's drape and the end offset (ticket 24) working. A sharp-turn arc is
      emitted as waypoints, so the follower's arrival rule (ticket 23) must still hold.

## Not in this ticket
- Search's node placement (ticket 25's path-length item), which picks the corridor; this
  ticket only changes how the corridor is pulled tight.
