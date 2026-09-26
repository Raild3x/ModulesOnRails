# 09: Winding groups

**What to build:** Regions are classified exactly: holes, unions and overlapping obstacles, via per-group winding. This is the first visualization of real behaviour.

**Blocked by:** 08

**Status:** ready-for-agent

- [ ] Group 0 for plain constraints; groups >= 1 must be balanced or `Triangulate` errors (U-d)
- [ ] The winding flood; `GetWinding`; invariant (d), winding equals ring containment at sampled points
- [ ] Every CDT fixture renders with triangles kept and excluded correctly (PNG review)

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
