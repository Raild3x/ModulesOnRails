# 09: Winding groups

**What to build:** Regions are classified exactly: holes, unions and overlapping obstacles, via per-group winding. This is the first visualization of real behaviour.

**Blocked by:** 08

**Status:** done

- [x] Group 0 for plain constraints; groups >= 1 must be balanced or `Triangulate` errors (U-d)
- [x] The winding flood; `GetWinding`; invariant (d), winding equals ring containment at sampled points
- [x] Every CDT fixture renders with triangles kept and excluded correctly (PNG review)

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **`Classify.luau`:**
  - A balance check on merged vertices, with an error naming the group (U-d).
  - A flood from a hull triangle, where the outside has winding 0. Crossing an edge adds ±1 per
    covering input edge of the group, signed by the input edge's direction relative to the
    edge's CCW direction. Steiner-split pieces keep their original edge's direction.
- **Invariant (d)** (`CDT.Winding.spec`): matches the direct point-in-polygon winding at every
  centroid.
  - It runs over the fixtures and 30 random, possibly self-intersecting, ring sets in three
    groups.
  - Negative control: a reversed reference ring is detected.
- **Finding:** the exact-geometry oracle can't judge slivers next to rounded Steiner vertices
  (about 1e-15 off the exact ring). Those are skipped, with an assertion that they stay under
  1% of triangles. NavMesh avoids them entirely (SR2: grid points only, no CDT Steiner
  vertices, guarded).
- **Open constraints in tests** now declare group 0; the default group-1 open edge errors
  (tested).
- **Specs:** 71/71, 98.4% lines, 93.2% branches. Mutation: a sample of 60, 52 killed (88.3%).
- **PNG review** (the visualization milestone), via
  `lune run tools/navmesh/render.luau tools/navmesh/scenes/cdt <out>`:
  - `Classified_*` views apply the NavMesh keep rule (walkable > 0, obstacle == 0, inside the
    tile).
  - The Courtyard scene (L-shaped walkable, a CW hole, overlapping plus rotated obstacles, a
    tile clip) is kept exactly where expected.
  - Overlapping obstacles are excluded as a union, including the doubly-covered overlap.
