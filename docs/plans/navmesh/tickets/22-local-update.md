# 22: Local Update and precise invalidation

**What to build:** `Update` costs proportional to the dirty tiles, and a game can tell which
paths a change actually broke.

**Blocked by:** 18. The hardening fixes in `Tiles.luau` (commit 8c4fbfe) must merge first.

**Status:** needs-triage (from the dogfood report, `examples/navmesh-demo/REPORT.md`, pain
points 2 and 4)

- [ ] One 4x4 crate on the 256-stud bench map costs about the spec's local re-snap figure
      (0.61 ms plus clearance), not today's 10-24 ms; the cost must not grow with the map size
- [ ] `TileSize` changes the `Update` cost the way the tile count predicts
- [ ] `Update` returns the changed regions (floor plus plan box, or tile ids)
- [ ] A path whose corridor avoids every changed region stays valid. Today one door toggle
      invalidates 199 of 200 unrelated paths on the demo level.
- [ ] The oracle "Update equals a fresh Build" still holds, including the hardening cases
- [ ] **Fix the reach-rule miss that predates this work.**
  - Found by the ticket 22 prototype oracle, `zz_oracle_proto.luau` on branch
    `proto/local-update`. The unmodified 8c4fbfe code passes 46/48 bench-map checks.
  - On props, with the crate at (36, 36), one rebuilt triangle keeps a stale corner width:
    0.827525 against a fresh Build's 0.827329. The triangle is 0.93 studs from the crate box,
    with a reach of 0.64.
  - Forcing a full clearance recompute gives 48/48. So the ticket 18 reach bound misses a
    width that the change does affect.

## Evidence
- **Whole-map cost:** `Tiles.luau` `apply` builds a fresh `Storage.New()` on every call. It
  copies every clean tile through `CopyOut`, rescans every triangle of the floor for heights,
  re-snaps every link, reruns `Connect`, and loops over all of `remap` once per changed box.
- **Bench:** `examples/navmesh-demo/bench.luau` measures a crate on several maps. `TileSize`
  64/32/16/8 gives 24/15/16/25 ms, which is flat, so the cost is not in the dirty tiles.

## Open design fork (benchmark before ruling)
1. **In-place range swap:**
   - Build the dirty tiles into scratch storage, validate, then swap their ranges in place.
     The SR14 range allocator already frees and reuses ranges.
   - Keep a per-floor height map rather than rescanning triangles.
   - Atomicity comes from validating the scratch before any write.
2. **Keep the fresh state, but copy clean tiles as ranges:** bulk `table.move` instead of
   per-triangle tables. Less change, but still O(map).

Prototype both on the bench maps before presenting them.

## Precise invalidation options
- Stamp per triangle range, not per tile.
- Or have `IsPathValid` test the path's stored corridor triangles against the changed boxes.
- The path already carries `TileStamps`. Storing the corridor would cost memory per path.
