# 14: FindPath basics

**What to build:** NPCs get smoothed paths across a floor, with correct statuses.

**Blocked by:** 13

**Status:** ready-for-agent

- [x] Snap using feet positions (U-b), A* with the admissible heuristic (SR7), the funnel at radius 0, all five statuses
- [x] The open-list benchmark (Heap vs bespoke), presented with numbers; path PNGs (`tools/navmesh/scenes/paths`)

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Built (2026-09-27)
- `Snap.luau`, `Search.luau` (the A* and its weak per-mesh scratch pool), `Funnel.luau`, and
  `NavMesh.FindPath`. `ToDrawList` takes an optional path.
- **Node placement:** entry-edge midpoints. Nodes at triangle centres bent a clear straight line
  by 30%; see bench.md, "Where A* puts a triangle's node".
- **Funnel fix:** an end snapped onto a portal edge makes the funnel flat. An unchanged endpoint
  now only advances its index, so no false corner is emitted.
- **Deferred:** `TileStamps` is returned empty until ticket 18. `AgentRadius` arrives with
  ticket 15.
- **After the gate (80.7%):** survivors pointed at thin snap and funnel tests, so oracles were
  added.
  - The funnel must be the tight string through its own corridor. That found a duplicated apex
    corner, where a side still at the apex read as crossed, and zero-turn corners where a line
    grazes a vertex. Both are fixed.
  - Snapping must not depend on the tiling (it kills the tile-filter mutants).
  - Snaps onto slopes and off edges in Z; the exact extents; zero-size extents; the NoStart and
    NoGoal cost; one expansion versus none.
