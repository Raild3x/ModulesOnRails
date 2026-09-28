# 17: Spatial queries

**What to build:** The remaining query API works on real meshes.

**Blocked by:** 15, 16

**Status:** ready-for-agent

- [x] `FindNearestPoint`, `Raycast`, `MoveAlongSurface`, `FindDistanceToWall`, `FindRandomPoint` (seeded)
- [x] The grid-vs-quadtree locate benchmark (bench.md, "Locating the snap candidates")

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Built (2026-09-27)
- **`Queries.luau`:**
  - **`Walk`:** a straight surface walk in X/Z across neighbours and seam portals. It stops at
    walls and excluded areas.
  - **`DistanceToWall`:** a search outward over reachable triangles, pruned by the best
    distance so far.
  - **`Move`:** slides along walls (up to 4 slides), then pushes out to the agent's radius
    without walking through another wall.
  - **`RandomPoint`:** uniform in plan over allowed triangles, sampled per triangle's plan area.
    A circle is handled by rejection sampling, 32 tries.
- **Public functions:** `FindNearestPoint`, `Raycast`, `MoveAlongSurface`,
  `FindDistanceToWall` and `FindRandomPoint`, plus the `NavPoint` type.
  - `Raycast` from off the mesh returns (true, from).
  - `FindDistanceToWall` off the mesh returns 0.
  - `MoveAlongSurface` from off the mesh errors.
- **Snap locate:** the tile hash plus box reject, from the benchmark.
- **Specs** (`NavMesh.Queries.spec`):
  - exact stops at walls and excluded areas, across tiles, and up a ramp onto the next floor;
  - sliding, and the radius push-out;
  - 300 random moves that never leave the mesh;
  - wall distance against rays, and its normal;
  - seeded reproducibility, uniformity in plan, and excluded areas for random points;
  - the snap box meeting a tile line.
  - Negative controls, each failing the right tests: the exit sign flipped, the normal flipped,
    no sliding, no radius push, no area weighting, and the tile-line boundary.
- **Known limits:**
  - `Raycast` is a point ray (no `AgentRadius`).
  - A walk stays on the floor it's on unless it meets a seam portal.
  - Random points in a circle may return nil after 32 misses when little of the circle is on
    the mesh.
