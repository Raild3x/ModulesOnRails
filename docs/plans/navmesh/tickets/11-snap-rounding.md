# 11: Snap-rounding prototype

**What to build:** The highest-risk NavMesh algorithm is proven early: authored polygons become grid-snapped, non-crossing constraints.

**Blocked by:** 05

**Status:** ready-for-agent

- [ ] Iterated snap rounding with exact hot-pixel tests via `CDT.Orient2D`
- [ ] A no-crossing invariant over seeded random polygon soups; the +/-32,768 guard (U-d)
- [ ] Screenshots of soups before and after snapping

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".
