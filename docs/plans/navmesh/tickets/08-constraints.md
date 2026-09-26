# 08: Constraint edges

**What to build:** Constraint edges are forced into the triangulation, including crossing and overlapping ones and exact duplicate points.

**Blocked by:** 07

**Status:** ready-for-agent

- [ ] Constraint recovery, crossing and overlap splits, exact-duplicate merge, covering edges exposed through the Count/Get readers
- [ ] Invariant (b): every input constraint is a chain of edges covered by its id
- [ ] Goldens and PNGs of the constrained fixtures

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
