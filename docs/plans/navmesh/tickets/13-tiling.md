# 13: Tiling

**What to build:** Floors are split into tiles with identical shared boundaries and neighbours linked across them.

**Blocked by:** 12

**Status:** done (default TileSize awaiting the user's ruling)

- [x] Canonical tile boundaries (SR3), cross-tile adjacency and its symmetry invariant, area groups
- [x] The default-`TileSize` benchmark, presented with numbers

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **Design (spec SR3 updated):**
  - Each floor is snap-rounded once, together with the origin-aligned tile grid lines. The
    grid spans every ring, including obstacles and areas that reach past the walkable surface.
  - Each tile clips the snapped ring chains to its rectangle (Sutherland-Hodgman, no new
    rounding, so winding groups stay closed) and adds every snapped vertex on its border.
  - Vertices are interned per floor by grid point. Cross-tile neighbours are linked by
    matching reversed open edges.
  - Empty tiles are not stored.
  - Rings, crease fragments and border vertices are bucketed per tile by bounding box. This
    removed an O(tiles x rings) clip scan and cut 8-stud builds by a third.
- **Bugs found while building:**
  - A tile whose clip holds fewer area groups read winding past its CDT's group count (out of
    bounds, or silently the next triangle's data). The area loop is now bounded by
    `GroupCount`.
  - Tile lines spanned only the walkable bounding box, so an obstacle reaching past it crossed
    a line extension with no vertex. The internal-error guard caught it.
  - The sliver height fallback used a constant ring height. It is now the plane of the
    nearest inside surface triangle; a sloped negative control confirms the fix.
- **Specs:** navmesh 66/66.
  - Tiling at 3, 5.5 and 8 studs over every fixture: structure, region, a **wall oracle**
    (no wall off an authored edge, so no T-junction or unlinked border) with its negative
    control, triangles inside their tile, and an area drift within perimeter/512.
  - Heights and the TwistedQuad crease under tiling.
  - Grid alignment and empty-tile skipping.
  - 30 random sloped floors with random tile sizes, checking heights against the plane.
  - TileSize validation.
- **Coverage and mutation:** lines 716/720; mutation 83.9%. The new survivors are equivalent:
  - grid-range widening (only visits tiles with no walkable content);
  - the crossing formula on axis-aligned edges (the multiplier is 0);
  - `hasWalkable` (a performance flag only);
  - the fallback distance maths (every test surface is planar).
- **PNGs reviewed:** Courtyard, TwistedQuad and ShallowObstacles at 5.5-stud tiles, plus the
  new default-tile golden.
- **TileSize benchmark:** in bench.md, run in Studio as 3 runs x 3 rounds on a 256-stud map
  with 655 obstacles.
  - **Recommendation:** 32 studs. Rebuilding one tile takes about 1.9 ms, at a cost of 12%
    more triangles.
  - `DEFAULT_TILE_SIZE = 32` is provisional until the user rules.
- **New tools:**
  - `tools/navmesh/bench/tilesize.py` (Studio);
  - `TileSize.luau` (the benchmark core, with `Run` and `Map`);
  - `tilesize_lune.luau` (a quick Lune gauge);
  - `profile_build.luau` (a per-phase profile of Build).
