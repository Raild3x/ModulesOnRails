# 23: Path follower

**What to build:** An optional helper that moves an agent along a `PathResult`, so every game
doesn't hand-roll about 150 lines with the same traps.

**Blocked by:** none (it uses the public API only)

**Status:** needs-triage (dogfood report, pain point 3; `Game.luau` `follow` is the
hand-rolled version to replace)

- [ ] It advances by `maxStep` per call along the waypoints, using `MoveAlongSurface` for the
      walkable segments
- [ ] **Arrival:** it treats the radius-pushed stop as arrived. A goal or a `Partial` end
      sits on the wall, and the agent stops `AgentRadius` short, or radius×√2 in a corner.
- [ ] **Links:** on a `Label` waypoint it emits a link event (label, from, to) and does not
      walk the segment to the landing
- [ ] **Blocked:** it reports the agent as blocked when progress stalls or the agent is left
      off the mesh (a door closed on it). It never throws.
- [ ] A spec drives the demo level's trap cases: a `Partial` end on the door face, the
      balcony corner, the jump link, and a door closing on the agent

## API sketch (to rule)
- `NavMesh.Advance(mesh, path, cursor, position, maxStep, filter) -> (position, floor, cursor, event)`
- `event` is `nil | "Arrived" | "Link" | "Blocked"`.
- The helper stays plain functions over plain data, like the rest of the API. There is no
  agent object.

## Related
- **Alternative:** offset `FindPath`'s end point by the radius (see ticket 24). The follower
  then only needs the arrival tolerance in corners.
- **Out of scope:** crowd avoidance and separation (spec).
