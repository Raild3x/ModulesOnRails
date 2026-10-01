# 33: Map scenario harness

**What to build:** A way to build a Part-based test map, run named pathfinding scenarios on it,
and see pass/fail, numbers and a picture.
- It runs headless under Lune through the Part adapter, the way the adapter's own specs build
  Parts.
- It renders in Studio for screenshots.
- Every complex-map ticket (34-38) adds a map and scenarios to it.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] **Map definition:** a map is a function that creates Parts (walkable, obstacles, areas
      through `NavArea`, links) and returns them with named points (spawns, goals).
- [ ] **Scenario definition:** a start point, a goal point, a filter (radius, area costs and
      so on), and expectations, each optional:
  - the path status;
  - the floors visited, in order;
  - the link labels used;
  - the area ids avoided;
  - a length bound, relative to the straight line or a reference path.
- [ ] **Runner:** builds the map through the adapter, then `NavMesh.Build`, then runs every
      scenario.
  - It prints a table: scenario, pass/fail, the expectation that failed, path length and
    `FindPath` time.
  - It also prints Build ms, triangle, floor and seam counts, and bake bytes.
- [ ] **Studio:** a command builds the same map as a place, draws the mesh and every
      scenario's path, and captures a PrintWindow screenshot.
- [ ] **Tracer map:** a flat lot with one crate, and one scenario that must route around it.
- [ ] **Negative control:** a scenario with a deliberately wrong expectation fails, and the
      runner reports which expectation failed.
- [ ] The harness and its tracer map run in the navmesh spec run, or one command beside it,
      so later maps become regression checks.
