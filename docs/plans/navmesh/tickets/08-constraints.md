# 08: Constraint edges

**What to build:** Constraint edges are forced into the triangulation, including crossing and overlapping ones and exact duplicate points.

**Blocked by:** 07

**Status:** done

- [x] Constraint recovery, crossing and overlap splits, exact-duplicate merge, covering edges exposed through the Count/Get readers
- [x] Invariant (b): every input constraint is a chain of edges covered by its id
- [x] Goldens and PNGs of the constrained fixtures

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Result
- **Recovery:** Sloan's edge recovery, which walks the segment and flips crossed edges whose
  quad is convex.
- **Collinear vertices** split a segment in two.
- **A crossed constraint** gets a Steiner vertex, inserted through the exact point insertion,
  and both constraints are re-routed through it keeping their ids.
- **Overlapping collinear constraints** share covered edges (multiple ids).
- **Edge lookup** uses a vertex→triangle map maintained on every write.
- **Two real bugs found by the random soups**, both fixed:
  1. Post-recovery restoration re-checked only 2 of the flipped quad's 4 outer edges (the
     point-insertion shortcut). There is now an all-sides mode.
  2. Un-constraining a crossed edge could leave non-Delaunay edges. A global Lawson pass now
     runs after all constraints are inserted.
- **Stress:** 300 mixed soups gave 0 invariant failures and 0 errors (321 ms); 60 of them are
  kept in the spec.
- **Specs:** 62/62, 98.1% lines.
  - Cases: fixtures as constraints, a forced non-Delaunay diagonal, the crossing X (Steiner at
    exactly (5,5)), collinear sub-edges, overlaps, duplicate and zero-length constraints, and a
    grid of bars (36 Steiner vertices).
  - Invariant (b) has a negative control, and there are 2 goldens.
- **PNGs reviewed:** Constrained_OverlappingObstacles (no triangle crosses a constraint;
  Steiner vertices at the obstacle crossings), GridOfBars, CrossingX.
- **Mutation:** a sample of 60 of 1195 mutants, 45 killed (76.7%). Survivors not yet triaged.
