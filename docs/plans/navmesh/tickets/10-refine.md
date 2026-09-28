# 10: Refine

**What to build:** Callers can refine a triangulation to minimum-angle and maximum-area bounds, and it always terminates.

**Blocked by:** 09

**Status:** ready-for-agent

- [x] Hull edges act as segments; the `MaxSteiner` default and budget halt; input angles are skipped
- [x] The angle and area bounds are checked by the invariants; PNGs (`tools/navmesh/scenes/refine`)

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Built (2026-09-27)
- `Refine.luau` (Ruppert) plus two Triangulator hooks: `SplitSegment`, which now also splits
  hull edges, and `InsertAt`.
  - Encroached segments are split first.
  - Then each bad triangle's circumcentre is reached by a straight walk that stops at segments.
    If a segment is in the way, or the circumcentre would encroach a segment in its cavity, the
    segment is split instead.
- **Midpoints only:** midpoints of dyadic coordinates are exact, so a split hull edge stays
  straight and the strict convex-hull invariant still holds. There are no concentric-shell
  splits; the budget halts instead.
- **P6 skip:** a triangle whose smallest angle lies between two segments.
- **Winding without the input:** refinement never moves a triangle across a constraint. Old ids
  keep their winding, and new triangles copy it across unconstrained edges.
- **Specs** (`CDT.Refine.spec`):
  - every fixture after refining: bounds, `Invariants.Check`, winding against ring
    containment, and no segment left encroached;
  - a flat hull;
  - a small input angle;
  - the budget: explicit, the default of 1024, and exactly at the finish;
  - options validation.
  - Five negative controls (no P6 skip, hull edges not segments, no winding repair, angles never
    bad, no cavity check) each turn tests red.
- **Not done:** `spec.md` still needs a line on midpoint-only splitting (after ticket 14's
  commit). Refinement rescans every triangle on each pass; a work queue can come if it shows up
  in a profile.
- **After the first gate (83.0%):**
  - **New tests from the survivors:** the MaxArea boundary; the budget spent while splitting
    segments; the default budget growing with input size; and seeded random point and
    constraint soups.
  - **The soups found real bugs.** Constraint crossings can leave Steiner vertices within
    1e-12 of an input vertex. Refine then split segments of about 4e-13, whose midpoints aren't
    exactly on the segment. That broke the hull's convexity, produced inverted triangles, left
    non-Delaunay edges, and exhausted the budget.
  - **The fixes:**
    - A split must be exact: a hull midpoint exactly on its edge, and every new triangle
      strictly CCW. A segment that fails is left unsplit, and Refine returns false.
    - `SplitSegment` re-checks every side of the triangles it creates.
  - **Re-gate:** 82/82, lines 98.9%, mutation 83.7%.
