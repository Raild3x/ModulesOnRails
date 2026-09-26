# 07: Unconstrained triangulation, end to end

**What to build:** Points go in and a Delaunay triangulation comes out: readable, locatable, and **visible** as a PNG.

**Blocked by:** 05, 06

**Status:** ready-for-agent

- [ ] `CDT.Triangulate` for points only (incremental insertion), plus the readers and `Locate`
- [ ] An invariant checker (CCW, neighbour symmetry, local Delaunay via exact non-strict incircle, `PlainData`) run over the fixtures and seeded random point sets, including cocircular and collinear ones
- [ ] `CDT.ToDrawList`, goldens, a CDT scene module, and PNGs reviewed through the screenshot loop

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
