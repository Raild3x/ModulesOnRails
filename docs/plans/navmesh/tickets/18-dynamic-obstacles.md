# 18: Dynamic obstacles

**What to build:** Doors and crates can be added and removed at runtime, cheaply and safely.

**Blocked by:** 15, 16

**Status:** ready-for-agent

- [ ] Atomic `Update` with rollback (SR13), tile and vertex reclamation (SR14), snapped-bbox dirtying, clearance refresh
- [ ] Add then remove equals a fresh Build; toggling doesn't grow memory

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Design notes (ruled 2026-09-26, before building)
- **Local re-snap (spec SR13):** `Update` snap-rounds only the dirty tiles.
  - Input: each dirty tile's static baseline fragments (its `TileSources`, kept by Build),
    plus every active dynamic obstacle overlapping the region, plus the tile rectangles.
  - Rebuilding from the baseline, not the current fragments, is what makes add-then-remove
    exact.
  - Prototype and checks: `tools/navmesh/bench/ab/localsnap.luau`. Port its four checks into
    the ticket's specs: no crossings, an unchanged outer border, an exact add-then-remove, and
    equality with a floor-wide re-snap. Keep the narrow-region negative control.
- **Tile size is per floor:** Build picks it from density unless `TileSize` is given, so
  `Update` must read each floor's tile size (from its tile bounds, or a stored per-floor
  value) rather than assume one.
