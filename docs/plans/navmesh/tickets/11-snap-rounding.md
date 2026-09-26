# 11: Snap-rounding prototype

**What to build:** The highest-risk NavMesh algorithm is proven early: authored polygons become grid-snapped, non-crossing constraints.

**Blocked by:** 05

**Status:** done

- [x] Iterated snap rounding with exact hot-pixel tests via `CDT.Orient2D`
- [x] A no-crossing invariant over seeded random polygon soups; the +/-32,768 guard (U-d)
- [x] Screenshots of soups before and after snapping

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **`lib/navmesh/src/Quantize.luau`:**
  - `ToGrid` (1/256 grid; errors outside +/-32,768 studs and on NaN).
  - `SnapRound(coords, edges) -> (coords, edges, source)`:
    - input vertex indices are kept, and new hot-pixel vertices are appended;
    - each fragment keeps its source segment's direction, so winding groups survive;
    - `source` maps each fragment back to its input edge.
- **Exactness (spec SR2 updated):**
  - Pixels are half-open, and hits are decided by Liang-Barsky on doubled grid integers (all
    products < 2^50).
  - Crossings are found with `CDT.Orient2D`.
  - A crossing within 1e-6 of a pixel edge marks every candidate pixel hot.
- **Bug caught while writing expectations:**
  - When a segment passes exactly through a pixel corner, the pixel touched only at the corner
    and the pixel entered there share the same entry parameter. Without a tie-break
    (closed-before-open), the route zigzags: "5,3,3,1,1,3,3,1,1,6".
  - Two tests pin the tie-break (x-closed and x-open corner ties), and a negative control
    confirmed the first fails without it.
- **Tests** (`NavMesh.Quantize.spec`, 13 new; navmesh 15/15):
  - all 4 corners x 2 directions;
  - no overshoot past either end;
  - collinear overlap and a T-junction add no vertex;
  - input-vertex reuse;
  - a crossing on a pixel edge.
  - **Invariant**, over 120 seeded soups, including shallow near-parallel ones (>1000
    fragments):
    - no proper crossing;
    - no fragment enters the open pixel of a vertex that isn't one of its ends (ISR);
    - no zero-length fragment;
    - each source's fragments chain end to end;
    - `CDT.Triangulate` adds no vertex.
  - 60 seeded self-intersecting ring sets in group 1 stay balanced (Triangulate accepts them).
  - **Negative controls:**
    - more than 30 of 40 raw soups violate the invariant and force Steiner vertices;
    - a near-miss fragment is flagged.
- **Coverage:** lines 136/137 (the depth guard is the only miss). Mutation score is 88.8%, and
  all 29 survivors are equivalent:
  - the key constants and the error level;
  - the initial [0,1] bounds, redundant given the tight bbox prefilter;
  - `b > 0`, since b is always even;
  - upper-bound ties, which can't matter;
  - the crossing prefilters and orientation products, where collinear and touching cases only
    reach endpoints that are already hot;
  - the depth guard.
  - The mutation triage also removed unreachable code: the axis-aligned `a == 0` branch, the
    infeasible-exit path, and the upper-bound tie handling.
- **Screenshots:** `lune run tools/navmesh/render.luau tools/navmesh/scenes/snap <out>`.
  - Soup7, Soup12, Shallow8 and Corners, each before (crossings in red) and after (hot pixels
    in amber, fragments in blue). Reviewed.
  - The corner scene shows only the bottom-left corner line routed through the origin pixel.
- **Ceilings (`ponytail:` comments):**
  - all-pairs crossing scan, O(n^2);
  - a linear hot-pixel scan per fragment.
  - Bench before optimizing, once Build feeds real tile segment counts (ticket 12).
- **Glossary:** "Grid" and "Snap rounding" were added to `lib/navmesh/CONTEXT.md`.
- **Tooling bug found:** `npm run setup <pkg>` deleted the tracked `lib/*/.coverage-ignore`
  files (from ticket 02). Setup clears each package down to `WALLY_IGNORE_LIST`, and that list
  didn't include them.
  - **Fix:** `.coverage-ignore` was added to that list in `scripts/_common.py`.
  - **Checks:** before the fix, setup deleted both files; after it, a re-run of setup kept them.
  - **Why no spec caught it:** the Python scripts have no test harness, and none was added for
    a one-entry list fix.
