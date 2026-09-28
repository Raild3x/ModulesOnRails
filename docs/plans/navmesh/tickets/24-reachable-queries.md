# 24: Off-mesh policy and closest-reachable queries

**What to build:** One consistent answer when a position is off the mesh, and queries that
find the closest usable point.

**Blocked by:** none

**Status:** needs-triage (dogfood report, pain points 5 and 7; repros 3 and 5)

- [ ] **One documented off-mesh policy.** Today five queries do five things for an agent a
      door closed on:

      | Query | Result |
      |---|---|
      | `FindPath` | NoStart |
      | `FindNearestPoint` | nil |
      | `Raycast` | blocked at `from` |
      | `FindDistanceToWall` | 0 |
      | `MoveAlongSurface` | throws |

      At minimum, `MoveAlongSurface` must return a status instead of throwing.
- [ ] `FindNearestPoint` gains a search radius: the closest point however far, bounded by the
      radius
- [ ] A `FindPath` option snaps an unreachable or off-mesh goal to the closest reachable
      point, instead of returning `NoGoal`
- [ ] `FindRandomPoint` honours `AgentRadius`, or the rejection stays documented, which it is
      as of 3ce0e7c.
  - Repro 3: 652 of 1,000 points lie closer than r=2 to a wall.
  - Fix: sample only triangles whose clearance admits the radius, then push the point off
    the walls.
- [ ] Whether `FindPath`'s end point is offset by `AgentRadius`. Deciding yes also makes
      ticket 23's arrival rule trivial.
- [ ] `FindRandomPoint` takes an options table in place of five positional arguments (API
      break: rule it with the rest)
