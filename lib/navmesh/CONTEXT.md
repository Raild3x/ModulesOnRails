# NavMesh: context

A layered 2.5D navigation mesh for pathfinding queries, built on ConstrainedDelaunay.

## Glossary

- **Description**: the authored input (floors, seams, links) that a mesh is built from.
- **Mesh state**: the plain built data queries run on. Parameters of this type are named
  `mesh`.
- **Floor**: a named height-field region. Each point of its XZ footprint has one surface height,
  so geometry that overlaps itself is split into several floors.
- **Walkable ring**: an outline of walkable surface on a floor. Rings are unioned.
- **Obstacle**: a footprint cut out of a floor.
- **Area**: an integer surface class. Queries give each area a cost multiplier or exclude it.
- **Seam**: a walk-through segment shared by two floors, such as the top of a staircase.
- **Link**: a point-to-point action hop between surface points, such as a ladder, jump or
  teleporter. A link can be switched off.
- **Tile**: a square cell of a floor, aligned to the world origin. It is the unit the mesh rebuilds when obstacles change.
- **Clearance**: the widest agent that can pass through a place. It lets one mesh serve any
  agent radius.
- **Snap**: placing a query point onto the nearest floor surface.
- **Off the mesh**: a query point that doesn't snap within `SnapExtents`, such as an agent a
  closed door left inside an obstacle. No query throws for it; each answers with a status or
  an empty result (the policy table is in the `NavMesh` class doc).
- **Search radius**: `FindNearestPoint`'s optional bound for rescuing an off-mesh point: the
  nearest surface point within that plan distance, however far outside `SnapExtents`.
- **End offset**: `FindPath` pushes a path's last waypoint `AgentRadius` off the walls, so an
  agent can stand there. The end can differ from the goal by up to the radius.
- **Closest reachable point**: where `GoalFallback` ends a path whose goal doesn't snap: of
  every triangle the start can reach, the point nearest the goal in 3D (each triangle offering
  its point nearest the goal in plan), then end-offset. Bounded only by `MaxExpansions`.
- **Grid**: the fixed 1/256-stud lattice that every authored coordinate is rounded to before a
  build.
- **Snap rounding**: bending every authored edge through grid points so that no two edges cross.
  It happens at build time, to authored edges. Not to be confused with **Snap**, which works on
  query points.
- **Follower**: plain data (`NewFollower`) that `Advance` walks a path with, a step at a time.
  It reports arriving, reaching a link (which it never walks) and being blocked (stalled, or
  off the mesh).
- **Waypoint**: one point of a returned path. It carries a link's label when a link starts
  there.
- **Corner width**: the widest agent that can pass through a triangle between two of its edges.
  Only walls bound it.
- **Portal width**: the widest agent that can cross one edge.
- **Reach**: how far from a triangle a wall can still change one of its widths (half the width).
  It bounds how much clearance an `Update` recomputes.
- **Wall**: a mesh edge with no neighbour that is not open: the edge of walkable surface or of
  an obstacle. Tile, area and seam edges are never walls.
- **Open edge**: a seam edge. It has no neighbour on its own floor, yet it is walkable.
- **Seam portal**: the overlap of two floors' seam edges, stored as a crossing between their
  triangles. The floors' seam vertices may differ by up to one grid pixel.
- **Extra link**: a transition beyond a triangle's three edges, either a seam portal or a link.
- **Corridor**: the chain of triangles a path search returns, with how each was entered.
- **Funnel**: pulling a corridor tight into the shortest path through it.
- **Dynamic obstacle**: an obstacle added or removed at runtime. The change is pending until
  `Update`.
- **Dirty tile**: a tile an `Update` must rebuild: its rectangle, grown by one grid pixel,
  overlaps a changed obstacle.
- **Authored rings**: a floor's walkable, obstacle and area rings, quantized to the grid but
  not snap-rounded, each with its winding group. `Update` re-snaps the ones near its dirty
  tiles with the active obstacles, through Build's own code, so a rebuilt tile is exactly what
  a fresh Build would make (format v3). Before v3 it re-snapped each tile's stored *baseline*
  (the snapped input Build gave it), which could land a crossing one grid pixel off.
- **Barrier** (ticket 27): a chain of an agent's radius-r wall discs inside one triangle,
  closed at vertices or on wall edges. It can cut a path's start or goal off from an edge of
  its own triangle, which the search checks at query time.
- **Stamp**: a per-tile counter that changes when anything a path through that tile relies on
  changes. `IsPathValid` compares a path's stamps against the current ones.
- **Changed region**: a per-floor box `Update` returns around what it changed: whole rebuilt
  tiles, plus the triangles whose widths it recomputed. `FirstAffectedSegment` names the first
  segment of a path that one reaches, fattened by the agent's radius (ticket 28).
- **Bake**: a mesh serialized to a versioned buffer, to ship precomputed.
- **Pending change**: a dynamic obstacle added or removed but not yet applied by `Update`
  (`HasPendingChanges`).
- **Part adapter**: `NavMeshAdapter` (its own package, not the core): it turns anchored Parts
  into a description.
  - **Cut**: the footprint of a Part standing within the agent's height above a floor. It
    becomes an obstacle of that floor. The ground under a solid ramp is cut.
  - **Weld**: closing a hairline crack between two Parts of one floor by moving a corner onto
    the other Part's edge. It lives in the adapter because it adds walkable space.
