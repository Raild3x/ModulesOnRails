# 12: Single-tile NavMesh Build, end to end

**What to build:** A one-floor, one-tile description builds into a queryable mesh state and renders.

**Blocked by:** 09, 11

**Status:** done

- [x] Walkable plus obstacle rings, the keep rule, heights (SR6), copy-out through NavMesh Storage and its contract suite
- [x] The degeneracy guards and the "CDT added no vertex" guard; Build error messages
- [x] `NavMesh.ToDrawList`, goldens, PNGs

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **New modules in `lib/navmesh/src/`:**
  - `Storage.luau`: layout owner (R4b). Vertices are native `vector`; triangle vertices,
    neighbours, floor, area and tile are i32 buffers; the tile table is plain arrays. It holds
    only the subset this ticket needs (spec note added).
  - `Build.luau`: quantize and validate the rings, then per-ring height surfaces (SR6, with
    creases from non-planar rings only), snap rounding, one `CDT.Triangulate`, the keep rule
    and areas, heights with the agreement checks, and copy-out with the guards.
  - `DrawList.luau`: `NavMesh.ToDrawList` draws `Floor:<name>` triangles (by floor, or by area
    with `Areas`), walls on open edges, and tile bounds with `Tiles`.
  - `Types.luau`: public desc types. `NavMesh.luau` exposes `Build`, `ToDrawList` and the
    types.
- **One tile per floor for now:** the floor's walkable bounding box is the tile, in group 3.
  Tiling comes in ticket 13.
- **Fixtures:** Courtyard, SplitLevel, TwistedQuad and ShallowObstacles.
- **Scene:** `lune run tools/navmesh/render.luau tools/navmesh/scenes/navmesh <out>`. The PNGs
  were reviewed:
  - Courtyard: the hole, the merged overlapping crates, the crate notching the wall, the area-2
    patch and the tile bounds;
  - TwistedQuad: the crease (12,0)-(0,8) is kept on both sides of the obstacle;
  - ShallowObstacles: the thin crossing obstacles cut cleanly.
- **Specs** (navmesh 60/60):
  - `NavMesh.Storage.spec`: the contract suite, with its every-export completeness test.
  - `NavMesh.Build.spec`:
    - structure (CCW in X, Z; symmetric neighbours) and `PlainData.Check`;
    - the region oracle: centroids inside walkable minus obstacles, plus lattice coverage;
    - area ids;
    - the golden DrawLists (saved with `SAVE_SNAPSHOTS=1` after the PNG review);
    - heights on SplitLevel, TwistedQuad (with a straddle negative control), a tilted planar
      ring, a notch pad, and the slanted-crease tolerance;
    - ring normalisation: CW, a closing duplicate, consecutive duplicates, collinear points;
    - 19 error messages;
    - 40 seeded random floors (never trip the added-vertex guard, and the region oracle
      holds), with a negative control on the region check.
  - `Tests/Helpers/MeshChecks.luau` is whole-file ignored in `.coverage-ignore`.
- **Negative controls, run by hand:**
  - the golden kills a tile-bounds mutant;
  - the notch-pad test kills `inside >= 0`;
  - the slanted-crease test kills a tolerance of 0. Its failure names the snapped crossing,
    which is the reason the tolerance exists.
- **Coverage:** lines 552/560. Three uncovered decisions are guards that can't fire:
  - the added-vertex guard (ticket 11 proves it);
  - the degeneracy guard, since stored X and Z are exact grid/256 in f32, so the orientation
    is preserved;
  - the no-containing-ring fallback for slivers.
- **Mutation:** 86.0% (it was 82.5% before the gap tests). The survivors are equivalent:
  - error levels and message formatting;
  - the reversal index literals, since one mutant yields a rotation of the reversed ring;
  - zero-origin bounds;
  - redundant crease constraints;
  - the unreachable guards;
  - growth-threshold boundaries.
- **Bug found by a strengthened test** (the tilted-planar ring moved off the origin, to kill
  the `x - x1` vs `x + x1` mutants):
  - Authored heights are f32 (`Vector3`/`vector`), so the planarity check's absolute 1e-9
    tolerance called nearly every tilted planar ring non-planar. Those rings got spurious crease
    constraints, which cut through obstacles and added snapped vertices (10 triangles instead
    of 8).
  - Fix: `PLANAR_TOLERANCE = 1e-3` studs.
  - Why no spec caught it: every earlier fixture height was exactly representable in f32. The
    test now uses 0.3x + 0.2z off the origin.
