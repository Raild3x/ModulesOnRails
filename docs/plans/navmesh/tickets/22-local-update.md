# 22: Local Update and precise invalidation

**What to build:** `Update` costs proportional to the dirty tiles, and a game can tell which
paths a change actually broke.

**Blocked by:** 18. The hardening fixes in `Tiles.luau` (commit 8c4fbfe) must merge first.

**Status:** built on `navmesh-local-update` (2026-09-28): Opt2i, and `Update` returns the
changed regions. From the dogfood report, `examples/navmesh-demo/REPORT.md`, pain points 2 and
4.

- [x] One 4x4 crate on the 256-stud bench map costs about the spec's local re-snap figure
      (0.61 ms plus clearance), not today's 10-24 ms; the cost must not grow with the map size
      *(with 8-stud tiles and cap 2: 2.6 / 1.3 ms add / remove, re-snap and triangulation about
      1.2 ms of it; a buffer copy of 0.1-0.2 ms per 1,000 triangles still grows with the map)*
- [x] `TileSize` changes the `Update` cost the way the tile count predicts *(64/32/16/8/4:
      39/10.6/3.9/2.6/4.3 ms add, against Base's flat 20-31 ms and 245 ms at 4)*
- [x] `Update` returns the changed regions (floor plus plan box, or tile ids) *(ruled
      2026-09-28: `{ Floor, Min, Max }` boxes; see As built)*
- [ ] A path whose corridor avoids every changed region stays valid. Today one door toggle
      invalidates 199 of 200 unrelated paths on the demo level. *(Ruled 2026-09-28: changed
      regions only; `IsPathValid` stays per tile. A game tests its paths against the returned
      boxes: a path clear of them is what `FindPath` returns again, which is a spec.)*
- [x] The oracle "Update equals a fresh Build" still holds, including the hardening cases
      *(it now also compares wall flags and vertex counts; one pre-existing limit below)*
- [x] **Fix the reach-rule miss that predates this work.**
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

## As built (2026-09-28, branch `navmesh-local-update`)
- **Ruling:** Opt2i (review.md, 2026-09-28). The commit still builds a fresh state and swaps it
  in, so atomicity stays free. Opt1 (in place) was rejected on atomicity risk; it remains a
  drop-in for the commit step if the O(T) copy ever matters. Opt2 alone was rejected because
  it is still O(map).
- **`Tiles.luau`:**
  - Everything that can fail runs first and reads the mesh only.
    - The dirty tiles come through Snap's tile hash (`Snap.TilesIn`, O(dirty)).
    - Heights and vertex ids come from the dirty tiles and their neighbours only.
    - The rebuilt tiles are triangulated and run through CopyOut's checks in scratch.
  - Then the fresh state is built.
    - `Storage.ShellFrom` shares the data an Update never changes.
    - Clean tiles are copied as buffer ranges (`CopyTriangleRange`) and renumbered in one pass
      (`RemapTriangles`).
    - Freed vertex slots take the new vertices, and the highest live ones move down.
    - Open edges are relinked around the rebuilt tiles only.
- **`Clearance.luau`:**
  - Build's wall index is kept in a weak per-mesh cache. It is runtime state and never
    serialized: a loaded mesh builds it on its first `Update`, from the state before the change.
    A Serialize spec covers that path; the loaded and original meshes update byte-identically.
  - `Refresh` swaps the rebuilt tiles' walls in the index. It then recomputes every triangle
    within its reach r* of a **changed wall** (one in the old walls or the new ones, not both),
    culling tiles by their largest width.
- **The reach-rule miss:** reach was measured from the obstacle's box. But a static wall
  crossing the obstacle gets a snapped vertex at the crossing, and that tilts the whole fragment
  back to its previous vertex, beyond the box.
  - The spec "widths follow a static wall the obstacle tilts" fails on the old rule.
  - A random search over slivers crossing a crate found width-only mismatches in 52/300 cases
    under the old rule, and 0/300 now.
  - The bench-map oracle now gives 48/48, up from 46/48.
- **Changed regions:** per floor, the rebuilt tiles' rectangles plus the boxes of the triangles
  whose widths were recomputed, merged where they touch. Y spans the triangles on both sides.
  - Spec: every changed triangle or width lies in a box, and a box shrunk by a pixel fails that.
  - Spec: a path clear of every box, its segments grown by its `AgentRadius`, is what
    `FindPath` returns again, unless the fresh path goes through a box (a removal can open a
    better way).
  - **Demo door toggle** (`examples/navmesh-demo/bench.luau`, 200 random paths, radius 0.5):

    | TileSize | tiles | paths meeting a region | `IsPathValid` flags |
    |---|---|---|---|
    | default | 3 | 197 | 199 |
    | 32 | 6 | 147 | 153 |
    | 16 | 15 | 111 | 128 |
    | 8 | 45 | 129 | 139 |
    | 4 | 162 | 94 | 106 |

  - The regions barely beat the stamps here, for two reasons:
    - With the default 3 tiles, the door's dirty tiles are most of the level.
    - The level is open, so its triangles are large and wide, and a recomputed triangle's box
      covers a room.
  - Smaller tiles and a lower `MaxAgentRadius` shrink the regions.
- **What the structure makes easy for precise invalidation (not built; needs an API ruling):**
  - `Clearance.Refresh` knows the exact changed walls and every recomputed triangle.
  - The plan knows the rebuilt tiles.
  - So `IsPathValid` could test a path's stored corridor, or its polyline, against those boxes
    instead of per-tile stamps. The path already records `TileStamps`, and its waypoints are
    enough for the polyline test used by the specs.
- **Bench:** `tools/navmesh/bench/update_lune.luau` (Base kept in `update_base/`); tables in
  bench.md "Local Update".
- **Open:**
  - **Update vs a fresh Build can differ by one grid pixel (pre-existing, since ticket 18).**
    - It happens where a dynamic obstacle crosses a *static* edge: Update re-snaps the tile's
      already-snapped baseline, whereas Build snaps the original input, so the crossing can
      round to the neighbouring pixel.
    - A random sliver search hit it in 79/300 cases, under both the old code and the new.
    - None of the spec fixtures or bench maps hit it. Fixing it would mean keeping each tile's
      unsnapped static input.
  - **Still O(T) or O(tiles):**
    - the range copy and renumbering pass;
    - the tile loop in the reach cull;
    - `Connect` (it rebuilds every seam and link);
    - the link re-snap.
  - Uncapped clearance costs about 0.3 ms per recomputed triangle.
  - The wall index stays in memory for the mesh's lifetime.
