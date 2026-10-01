# 31: Measure large worlds before ruling on region bakes

**What to build:** Numbers, not features. How do Build, the bake and queries scale on a
1-4 km authored map? The numbers decide whether region bakes (loading part of a mesh) are
needed.

**Blocked by:** none. It is bench-only and touches no `src`, so it can run beside any track.

**Status:** measured 2026-10-01 (Track H); D6 ruled 2026-10-01: fix the O(map) costs first, then re-measure (review.md). Ruled 2026-09-28 (review.md, D6: "Measure first"). From
[research/roblox-pathfinding-comparison.md](../research/roblox-pathfinding-comparison.md)
gap G7. Today's reference point: the 256-stud bench map bakes to 581 KB and builds in
213-595 ms (examples/navmesh-demo/REPORT.md, measured timings).

- [x] **Maps:** generated and seeded, in `tools/navmesh/bench/`, at 1, 2 and 4 km square
      (well inside the ±32,768-stud range):
  - **city:** a street grid with building footprints as obstacles, and some multi-floor
    buildings with seams;
  - **open:** a large floor with scattered props;
  - **terrain-like:** dense, slightly rotated rings, the input a terrain adapter would produce.
- [x] **Measure,** for each map and the default and two other `TileSize`s:
  - Build ms;
  - bake bytes;
  - Deserialize ms;
  - Luau heap after load;
  - `FindPath` across the map (median and p95 over seeded pairs, with and without
    `MaxExpansions`);
  - one `Update`.
  - Use the audited method in bench.md.
- [x] **Measure on both runtimes:** Lune, and one Studio run on the largest map (heap and
      Deserialize), since the bake ships to clients.
- [x] **Report** to bench.md, then present the D6 options with these numbers:
  - out of scope;
  - region bakes (tile-subset `Serialize` plus a merging `Deserialize`);
  - anything the numbers suggest, for example a smaller bake format before any region
    loading.

## As built (2026-10-01, Track H)
- **Maps:** `tools/navmesh/bench/LargeMaps.luau` (city, open, terrain).
- **Bench:** `large_world.luau` (Lune), on the shared core `LargeWorld.luau`.
  - The ticket asks for Build ms, bake bytes, `Deserialize` ms, heap, `FindPath` and `Update`.
    The bench adds two columns: the zstd size, and the cold-versus-warm load spike.
  - 4 km terrain ran once, at the default TileSize only, because its Build is quadratic.
- **Studio:** `large_world.py` runs on the 4 km bakes.
- **Profiles behind the reading:**
  - `update_profile.luau`, `deserialize_profile.luau`, `heap_fields.luau` and
    `bake_sections.luau`;
  - `profile_build.luau`, which gained a `largeMap` argument.
- **Repros:** `rings_repro.luau` and `tablemove_repro.luau`.
- **Results:** bench.md, "Large worlds, 1-4 km".
- **New gaps:** known-gaps.md, "Found by Track H". Two of them are library performance bugs:
  - Build and `Update` cost O(triangles x walkable rings);
  - appending with `table.move` is quadratic in `Storage`.
