# 18: Dynamic obstacles

**What to build:** Doors and crates can be added and removed at runtime, cheaply and safely.

**Blocked by:** 15, 16

**Status:** ready-for-agent

- [x] Atomic `Update` with rollback (SR13), tile and vertex reclamation (SR14), snapped-bbox dirtying, clearance refresh
- [x] Add then remove equals a fresh Build; toggling doesn't grow memory
  - **Correction (2026-09-28, dogfood repro 8):** triangle and vertex storage stays flat, but
    the removed obstacle *records* are kept forever. After 4,000 toggles, `Update` takes
    0.6 -> 4 ms and the bake grows from 1.4 KB to 91 KB. A fix is in progress on branch
    `navmesh-fixes`.

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Design notes (ruled 2026-09-26, before building)
- **Local re-snap (spec SR13):** `Update` snap-rounds only the dirty tiles.
  - Input: each dirty tile's static baseline fragments (its `TileSources`, kept by Build),
    plus every active dynamic obstacle overlapping the region, plus the tile rectangles.
  - Rebuilding from the baseline, not the current fragments, is what makes add-then-remove
    exact.
  - Prototype and checks: `tools/navmesh/bench/ab/localsnap.luau`. Port its four checks into
    the ticket's specs: no crossings, an unchanged outer border, an exact add-then-remove, and
    equality with a floor-wide re-snap. Keep the narrow-region negative control.
- **Tile size is per floor:** Build picks it from density unless `TileSize` is given, so
  `Update` must read each floor's tile size (from its tile bounds, or a stored per-floor
  value) rather than assume one.

## Built (2026-09-27)
- **Build refactor, output byte-identical:**
  - The per-tile pipeline is now `triangulateTile` plus `copyOut`, shared with `Update`.
  - Build records what `Update` needs in Storage as plain arrays: each tile's exact
    triangulation input, and each floor's tile size, areas and walkable rings (for heights).
  - It also records seam records and seam pieces. Every extra link (seams, then links
    re-snapped) is rebuilt by one `connect` step.
- **`Tiles.luau`:**
  - `AddObstacle` and `RemoveObstacle` are validated eagerly and stay pending until `Update`.
  - **Dirty tiles:** the rectangle grown by one pixel overlaps the snapped box.
  - **Rebuild:** a dirty tile with no active obstacle rebuilds from its baseline verbatim. The
    rest of a floor's dirty tiles are re-snapped together with the active obstacles (the local
    re-snap), and each gets its own fragments, the clipped obstacle chains, and its border
    vertices.
- **Commit model, simpler than slabs and free lists:**
  - `Update` builds a fresh compact state. Clean tiles are copied and renumbered, and vertices
    are re-interned by grid point. Then it swaps the state into the caller's table.
  - SR14 already makes ids stable only until the next `Update`. So there are no dead slots and
    no free lists, and memory can't grow: 20 toggles keep every array the same size.
  - Atomicity is free: an error before the swap leaves the mesh untouched, and the pending
    records are rolled back.
- **Clearance refresh:**
  - A rebuilt triangle with the same grid points as an old one keeps its widths, matched by
    vertex.
  - Triangles whose reach r* touches a changed obstacle box are recomputed (ruling U-a), and
    so are new triangles.
  - **Oracle:** `Update` with a door equals a fresh Build with the door baked in as a static
    obstacle: the same triangles and the same widths to 6 decimals, on all four bench scenes.
    It is also a spec on the Courtyard and ShallowObstacles.
- **Cost** (Lune, a 3 x 1.5 door, medians of 5 add/remove toggles):

| scene | Build | Update add / remove | first version |
|---|---|---|---|
| props (3152 tris) | 779 ms | 26 / 24 ms | 71 / 68 |
| bench (4605) | 650 ms | 27 / 20 ms | 66 / 59 |
| terrain (1297) | 255 ms | 13 / 11 ms | 88 / 85 |
| walls (692) | 155 ms | 20 / 10 ms | 63 / 55 |

  - The two speedups: reach is measured from the changed obstacle boxes rather than whole
    dirty tiles (1.7x), and unchanged rebuilt triangles keep their widths (a further 1.5-3x).
  - What remains is roughly clearance for new triangles, the O(T) copy, and re-triangulation.
- **Specs** (`NavMesh.Obstacles.spec`, 13):
  - pending changes until `Update`, and `IsPathValid` flipping;
  - add-then-remove equal to a fresh Build (canonical DrawList) on three fixtures;
  - the baked-obstacle oracle;
  - 20 toggles without growth;
  - the pixel margin at a tile line, and straddling a tile line;
  - local stamps, and clearance following obstacles;
  - seams and links across an update, and link ends through a renumbering;
  - a no-op update, eager validation, and rollback on an injected failure.
  - Negative controls, each failing the right test: no pixel margin, no clearance refresh, no
    stamp bumps, no rollback, stale link triangles, and no reach refresh.
  - "Always re-snap" passes on purpose: re-snapping an obstacle-free baseline is idempotent,
    so the verbatim path is a fast path.
- **Known limits:**
  - An obstacle over a link end takes that link out until it is removed.
  - Clearance near a seam still counts only its own floor's walls.

## Amended (2026-09-28): removed obstacle records are freed
- **The gap:** "memory can't grow" held for the mesh arrays but not for the obstacle records.
  Every record ever made stayed in the state, and `Update` copied all of them. After 4,000 door
  toggles `Update` went from 0.64 to 4.0 ms and the bake from 1.4 KB to 91 KB (dogfood report,
  `examples/navmesh-demo/repros.luau` repro 8).
- **Now** (ruling in review.md, 2026-09-28):
  - Storage holds only the live records, in id order, plus a next-id counter.
  - `Update`'s commit drops the records of removed obstacles, and a pending add that is removed
    goes at once, so a toggled door keeps one record.
  - Ids stay monotonic and are never reused. `RemoveObstacle` on a freed id still reports
    "already removed"; an id never handed out reports "no obstacle".
  - Rollback deletes the pending adds rather than marking them removed.
  - `Storage.OBSTACLE_REMOVED` is gone. The new accessors are `FindObstacle`,
    `GetObstacleState`, `RemoveObstacleRecord` and `Get`/`SetObstacleNextId`, and
    `GetObstacleRecord` takes a slot and returns the id first.
- **Spec:** `Obstacles.spec` "a door toggled all day keeps one record, a flat bake and a flat
  Update". Over 1,000 add/remove cycles the record count returns to 0, the bake returns to the
  obstacle-free size, and `Update` does not slow down. The negative control, the old
  Storage/Tiles, fails at the first cycle.
- **Repro 8 after** (10 / 1,000 / 4,000 toggles):

| | 10 | 1,000 | 4,000 |
|---|---|---|---|
| Update, before | 0.40 ms | 0.87 ms | 2.22 ms |
| Update, after | 0.41 ms | 0.40 ms | 0.39 ms |
| Bake, before | 1,367 B | 23,642 B | 91,142 B |
| Bake, after | 696 B | 696 B | 696 B |
