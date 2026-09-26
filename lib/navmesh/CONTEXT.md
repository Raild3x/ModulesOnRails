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
- **Tile**: a square cell of a floor. It is the unit the mesh rebuilds when obstacles change.
- **Clearance**: the widest agent that can pass through a place. It lets one mesh serve any
  agent radius.
- **Snap**: placing a query point onto the nearest floor surface.
- **Grid**: the fixed 1/256-stud lattice that every authored coordinate is rounded to before a
  build.
- **Snap rounding**: bending every authored edge through grid points so that no two edges cross.
  It happens at build time, to authored edges. Not to be confused with **Snap**, which works on
  query points.
- **Waypoint**: one point of a returned path. It carries a link's label when a link starts
  there.
