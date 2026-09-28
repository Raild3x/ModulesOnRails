# 31: Measure large worlds before ruling on region bakes

**What to build:** Numbers, not features. How do Build, the bake and queries scale on a
1-4 km authored map? The numbers decide whether region bakes (loading part of a mesh) are
needed.

**Blocked by:** none. It is bench-only and touches no `src`, so it can run beside any track.

**Status:** needs-triage. Ruled 2026-09-28 (review.md, D6: "Measure first"). From
[research/roblox-pathfinding-comparison.md](../research/roblox-pathfinding-comparison.md)
gap G7. Today's reference point: the 256-stud bench map bakes to 581 KB and builds in
213-595 ms (examples/navmesh-demo/REPORT.md, measured timings).

- [ ] **Maps:** generated and seeded, in `tools/navmesh/bench/`, at 1, 2 and 4 km square
      (well inside the ±32,768-stud range):
  - **city:** a street grid with building footprints as obstacles, and some multi-floor
    buildings with seams;
  - **open:** a large floor with scattered props;
  - **terrain-like:** dense, slightly rotated rings, the input a terrain adapter would produce.
- [ ] **Measure,** for each map and the default and two other `TileSize`s:
  - Build ms;
  - bake bytes;
  - Deserialize ms;
  - Luau heap after load;
  - `FindPath` across the map (median and p95 over seeded pairs, with and without
    `MaxExpansions`);
  - one `Update`.
  - Use the audited method in bench.md.
- [ ] **Measure on both runtimes:** Lune, and one Studio run on the largest map (heap and
      Deserialize), since the bake ships to clients.
- [ ] **Report** to bench.md, then present the D6 options with these numbers:
  - out of scope;
  - region bakes (tile-subset `Serialize` plus a merging `Deserialize`);
  - anything the numbers suggest, for example a smaller bake format before any region
    loading.
