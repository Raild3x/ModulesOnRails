# 07: Unconstrained triangulation, end to end

**What to build:** Points go in and a Delaunay triangulation comes out: readable, locatable, and **visible** as a PNG.

**Blocked by:** 05, 06

**Status:** done

- [x] `CDT.Triangulate` for points only (incremental insertion), plus the readers and `Locate`
- [x] An invariant checker (CCW, neighbour symmetry, local Delaunay via exact non-strict incircle, `PlainData`) run over the fixtures and seeded random point sets, including cocircular and collinear ones
- [x] `CDT.ToDrawList`, goldens, a CDT scene module, and PNGs reviewed through the screenshot loop

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **`Triangulator.luau`:** Morton-ordered incremental insertion into a bounding triangle, with
  an exact-`Orient2D` visibility walk.
  - Insertion handles 1->3 splits, 2->4 on-edge splits and exact-duplicate merges.
  - Lawson flips use exact `InCircle`.
  - Coverage heads travel with edges, ready for ticket 08.
- **Public API:** `Triangulate`, `Locate` and the Storage readers.
- **`ToDrawList`:** triangles, constraints, vertices and Steiner vertices, plus optional
  circumcircles.
- **Invariant checker** (`src/Tests/Helpers/Invariants.luau`):
  - CCW, neighbour symmetry and shared-edge agreement;
  - local Delaunay;
  - convex hull;
  - Euler T = 2V - 2 - H;
  - input mapping;
  - `PlainData`.

  It has negative controls for a clockwise triangle and a broken neighbour link.
- **Specs:** 51/51.
  - Inputs: fixtures, random sets up to 800, a 13x13 cocircular lattice, collinear-only input,
    duplicates, on-edge points, a 2^40 offset and tiny coordinates.
  - Also `Locate` over 500 queries, and 2 goldens.
- **PNG review** (`lune run tools/navmesh/render.luau tools/navmesh/scenes/cdt <out>`): Random200,
  the 9x9 lattice, and circumcircles showing the empty-circle property.
- **Scale:** 5,000 points in 35 ms (interpreted Lune). A 20,000-point run proved duplicate
  merging: the test generator repeated points, and V equalled the distinct count.
- **Mutation:** 52/60 killed (86.7%).
