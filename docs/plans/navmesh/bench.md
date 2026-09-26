# NavMesh Phase 0 benchmarks (B1: R4 data layout, B2: const vs local)

- **Environment:** Studio via `run-in-roblox` (plugin/edit context; F9 confirmed `--!native`
  applies there).
- **Method:** 3 separate Studio runs × 5 interleaved rounds (layout order rotated each round).
  Each cell is the best of 3 reps per round, then the median over rounds, then the median over
  runs.
- **Re-run:** the audited harness now lives in `tools/navmesh/bench/`. Run it with
  `python tools/navmesh/bench/run.py` (verification.md, F9).
- **Harness:** a scratchpad copy of `gen.py`, `bench/Mesh.luau` and `b1.luau`. One workload
  template is expanded per layout, so each layout gets monomorphic code and no layout pays for
  another's abstraction.

## Setup
- **Mesh:** a jittered 224×224 grid, **50,176 vertices / 99,458 triangles**.
  - Each cell is split along the diagonal chosen by the incircle test, so the mesh is locally
    Delaunay and the visibility walk terminates.
  - Triangles are CCW; edge i is opposite vertex i; neighbour 0 = none.
- **Workloads:**
  - **build:** fill the layout from the shared mesh.
  - **locate:** 2,000 visibility walks, each starting from the previous result.
  - **flood:** a BFS over neighbours with generation stamps; topology only.
  - **A\*-like:** Dijkstra over triangle centroids, corner to corner, with a binary heap; reads
    coords heavily.
  - **insert:** 20,000 1→3 triangle splits that append vertices and triangles, which exercises
    growth.
- **Correctness cross-check:** every workload returned the same value for every layout, in both
  native and interpreted modes, in all 3 runs.
- **Layouts:**
  - **A:** one interleaved number table `{x1,y1,…}` plus flat `TriVerts` and `TriNeighbors`
    tables.
  - **B:** split `X`/`Y` tables plus the same topology tables.
  - **C64 / C32:** `buffer` coordinates as f64 (16 B per vertex) or f32 (8 B), plus i32 topology
    buffers. Grown by doubling capacity.
  - **D3:** `{Vector3}` (the native vector value type) plus topology tables.
  - **D2:** `{Vector2}` (heap userdata) plus topology tables.
  - **E:** layout A read through accessor **functions**, i.e. the cost of a method-based API.

## B1 results: native (`--!native`), ms, median of 3 runs
| layout | build | locate | flood | A*-like | insert | held memory |
|---|---|---|---|---|---|---|
| A interleaved table | 7.77 | 27.03 | 3.26 | 33.71 | 13.59 | 10,892 KB |
| B split tables | 7.92 | 24.58 | 3.31 | **30.28** | 13.51 | 10,893 KB |
| **C64 buffer f64** | **3.18** | **16.66** | 3.43 | 34.80 | 5.28 | **3,116 KB** |
| **C32 buffer f32** | 3.56 | 17.03 | 3.33 | 34.37 | **4.01** | **2,724 KB** |
| D3 `{Vector3}` | 7.49 | 33.89 | 3.31 | 35.00 | 12.23 | 10,109 KB |
| D2 `{Vector2}` | 7.59 | 41.33 | 3.42 | 37.26 | 15.69 | 11,285 KB |
| E accessor functions | 6.92 | 51.99 | 4.73 | 47.53 | 18.63 | 10,893 KB |

## B1 results: interpreted (no `--!native`), ms
| layout | build | locate | flood | A*-like | insert |
|---|---|---|---|---|---|
| A interleaved table | 10.05 | 52.89 | 7.02 | 65.41 | 16.81 |
| B split tables | 5.70 | 49.14 | 7.12 | 57.25 | 16.65 |
| C64 buffer f64 | 8.95 | 55.26 | 6.89 | 75.42 | 11.78 |
| C32 buffer f32 | 8.93 | 55.18 | 6.38 | 73.84 | 10.73 |
| D3 `{Vector3}` | 7.47 | 51.40 | 7.21 | 59.00 | 13.71 |
| D2 `{Vector2}` | 9.80 | 58.55 | 6.86 | 62.14 | 16.18 |
| E accessor functions | 7.89 | 88.76 | 9.18 | 89.92 | 23.55 |

Memory is the Luau heap delta (`collectgarbage("count")`) while the structure is held. It was
identical across runs and matches the analytic sizes:
- a table slot is 16 B, so layout A holds 100k coord slots + 600k topology slots ≈ 11.2 MB;
- layout C64 holds 0.8 MB of coords + 2.4 MB of i32 topology ≈ 3.2 MB.

## Analysis
- **Buffers win decisively under native codegen** on everything that reads topology plus coords:
  - locate is **1.5–1.6x faster** than tables;
  - insert (growth) is **2.6–3.4x faster**;
  - build is **2.4x faster**;
  - memory is **3.5–4x smaller**, which also matters for replication and Serialize size.
- **Buffers lose when interpreted.** Without `--!native`, each `buffer.read*` is a call, and
  buffers are about 1.1–1.3x slower than tables on the A\*-like search. Buffers are therefore
  only the right choice together with `--!native`, which the cores will use anyway.
- **The A\*-like search is heap-bound:** about 30–35 ms regardless of layout. Split tables edge
  it out (30.3 vs 34.8). The open-list design matters more than coordinate storage there, which
  is a separate fork for the implementation plan.
- **Flood (topology only) is flat** across layouts, at about 3.3 ms.
- **`{Vector3}` is not free:** 2x slower on locate than buffers, with the same memory as tables.
  **`{Vector2}` is worst of the coordinate layouts,** because it's heap userdata.
- **Accessor functions cost about 2x on reads** against direct storage (E vs A). This is
  evidence that the CDT's public contract should expose raw storage (or a module-level
  function over it) rather than per-read method calls.
- **f32 vs f64:** 12% less memory and faster growth, with the same speed on reads.
  - **Precision caveat:** f32 has 24-bit mantissas. It is exact only for coordinates that are
    already quantized to the N2 grid (at 1/256 stud, up to ±32,768 studs).
  - Exact predicates are evaluated in f64 either way.
  - Choosing f32 would make the N2 grid a hard requirement of the CDT input, not just a
    NavMesh convenience.
- **Network:** buffers pass the F8 validator and replicate as compact binary. Remote transfer
  time and size were **not measured**, because run-in-roblox can't run a real server-to-client
  remote.

## B2 results: `const` vs `local` (layout A, native), 3 runs × 10 interleaved rounds
| binding | locate (per-run medians) | median | A*-like (per-run medians) | median |
|---|---|---|---|---|
| `local` | 26.38 / 25.52 / 28.47 | 26.38 | 34.18 / 33.74 / 36.64 | 34.18 |
| `const` | 27.21 / 26.46 / 26.65 | 26.65 | 34.59 / 34.00 / 34.32 | 34.32 |

**No measurable performance difference.** The winner flips between runs, and the gap (≤1%) is
far inside the ~5% run-to-run noise. Luau already treats never-reassigned locals as constants.
So the `const` question is decided by the **pipeline trade-off alone**: adopting `const` moves a
core to the Studio pipeline and gives up F2 (mutation testing), F3 (snapshots) and the fast Lune
loop.

## Raw runs
Per-run tables are kept in the scratchpad (`studio/b1_run{1,2,3}.txt`). Per-run medians for
every cell (native):

| layout | locate r1/r2/r3 | insert r1/r2/r3 |
|---|---|---|
| A | 27.03 / 26.08 / 28.40 | 14.39 / 13.59 / 13.04 |
| B | 24.58 / 24.91 / 24.15 | 13.49 / 13.88 / 13.51 |
| C64 | 16.44 / 17.12 / 16.66 | 5.20 / 5.36 / 5.28 |
| C32 | 16.84 / 17.03 / 17.69 | 3.89 / 4.87 / 4.01 |
| D3 | 33.90 / 33.89 / 33.24 | 13.70 / 11.92 / 12.23 |
| D2 | 39.85 / 42.07 / 41.33 | 14.70 / 15.82 / 15.69 |
| E | 48.98 / 52.28 / 51.99 | 18.28 / 18.63 / 18.67 |

## Independent audit (2026-09-25): SUPERSEDES the Analysis above where they conflict
- **Who:** an adversarial auditor agent, working from its own harness in the scratchpad
  `audit/` folder (`gen_audit.py`, `bench/Harness.luau`, raw `r2d_*` / `r3d_*`, `agg.py`).
- **Method:** `--!native`, medians of 3 Studio runs, each run the median of 5 interleaved
  rounds.
- **Verdict:** no rigging (the modules differ only in the storage macros), but the original
  conclusion was **overstated and misattributed**.

**Fairness issues the audit found in the original harness:**
1. **Confounded variable.** C64/C32 changed both the coordinate *and* the topology storage.
   The hybrid variants show that **i32 buffer topology** carries the win. Topology is also most
   of the memory: 9.55 MB as tables vs 2.39 MB as i32.
2. **Missing type annotations handicapped only `{Vector3}`.** Adding `local p: Vector3` took
   locate from 23.8 → 15.3 ms (grid) and 48.2 → 28.3 ms (shuffled). The same annotation did
   nothing for buffers.
3. **Weak cross-checks.** The insert check (`V + T`) was write-invariant, dijkstra was rounded
   to 1e-3 (which hid f32 differences), and only the last rep was kept.
4. **Unequal growth.** Tables were built exact-size, so they rehashed on the first append.
   Pre-sized, the insert gap shrinks from 3.1x to 1.8x.
5. **Mesh order was never tested.** On a mesh with shuffled vertex and triangle ids, table
   topology collapses (A locate 19.6 → 43.3 ms) while buffer topology barely moves (C64
   16.0 → 21.2).
6. **"A\*-like is heap-bound" was unsupported.** It depends on the layout, especially when
   shuffled.
7. **Build timing wasn't interleaved.** The ratio (~2.4x) still holds.
8. **The memory method was fragile.** The count deltas can go negative mid-GC. The analytic
   sizes stand.

**Corrected 2D results** (ms; grid / shuffled):

| layout | locate | dijkstra | insert pre-sized | memory |
|---|---|---|---|---|
| B split tables | 18.3 / 37.5 | 30.2 / 43.2 | 5.14 | 11.2 MB |
| table coords + buffer topology | 17.9 / 25.0 | – | – | 3.9 MB |
| buffer coords + table topology | 19.9 / 43.2 | – | – | 10.1 MB |
| C64 all-buffer | 16.0 / 21.2 | 33.4 / 37.6 | 2.95 | 3.2 MB |
| C32 all-buffer | 16.2 / 20.3 | 33.2 / 38.2 | 2.81 | 2.8 MB |
| D3 typed, scalar math, table topology | 15.3 / 28.3 | 28.2 / 40.1 | 4.72 | 10.3 MB |
| **D3 typed, `vector` lib, buffer topology** | 16.2 / 21.9 | **27.2 / 30.2** | 2.97 | **3.2 MB** |

**Corrected 3D results** (X, Y, Z; ms; grid / shuffled):

| layout | locate | dijkstra | insert pre-sized | memory |
|---|---|---|---|---|
| split tables, 3 components | 17.0 / 39.0 | 32.6 / 50.0 | 5.59 | 11.9 MB |
| buffer f64, 3 components (24 B) | 16.5 / 23.0 | 34.0 / 40.0 | 3.22 | 3.6 MB |
| buffer f32, 3 components (12 B) | 16.3 / 20.9 | 34.5 / 40.0 | 2.90 | 2.9 MB |
| **Vector3 + buffer topology** | 16.2 / 21.8 | **27.8 / 32.5** | 2.93 | **3.1 MB** |

**Vector math:**
- Typed `vector.cross` gives the fastest grid locate, 13.8 ms.
- `vector.magnitude` beats `.Magnitude`, 27.7 vs 32.2 ms.
- Untyped method calls are slow, 35.6 ms.
- `{Vector2}` is poor in every form (heap userdata), 100–145 ms idiomatic.

**Precision:**
- There are three result classes: f64; f32 storage (C32, and Vector3 read as scalars); and f32
  vector arithmetic.
- **Exact predicates must use scalar f64 math on the components, never f32 `vector.cross`.**
- Vector3 storage imposes the same N2 quantization requirement as C32.

**Conversion to and from Vector3** at the API boundary: under 10 µs per 1,000 waypoints, which
is negligible.

**Audited conclusion:**
- **Topology:** i32 buffers are a clear win (about 2x on shuffled locate, 4x less memory).
- **Coordinates:** roughly a tie between typed Vector3 and f32/f64 buffers. Decide on precision
  and API needs.

## Not accounted for (raised by the user after the first write-up)
- **Vector math was never exercised.** The D3/D2 layouts only read `.X`/`.Y` and then did
  scalar math. Idiomatic vector code is untested:
  - orientation as `vector.cross(b - a, p - a).Z`;
  - centroids as `(a + b + c) / 3`;
  - distances as `vector.magnitude`;
  - AABB tests with componentwise `vector.min`/`vector.max`.

  Under `--!native` these compile to SIMD, so the D3 numbers above are a *lower bound* on what a
  vector-native implementation could do.
- **Correction:** `Vector3` components are **float32**. The `{Vector3}` layout therefore has
  the same precision caveat as C32: exact only for grid-quantized coordinates. The analysis
  above attached that caveat only to C32.
- **3D storage:** NavMesh needs X, Y and Z (floor height). A Vector3 slot holds all three in
  16 B, while a buffer needs 24 B/vertex (f64) or 12 B (f32). The 2D benchmark flattered the
  buffers on memory for the NavMesh use.
- **API interop:** queries take and return `Vector3` (waypoints, raycasts), so a Vector3
  layout avoids conversions at the boundary. This is unmeasured.
- The independent audit has been asked to add vector-idiomatic variants.

## Default TileSize (ticket 13, 2026-09-26)
- **Command:** `python tools/navmesh/bench/tilesize.py --runs 3 --rounds 3 --map 256`, in
  Studio. The core is `tools/navmesh/bench/TileSize.luau`; a Lune gauge is at
  `tilesize_lune.luau`.
- **Map:** 256×256 studs, flat, with 655 randomly rotated box obstacles (2-8 studs across,
  one per 100 square studs) and 64 area patches. The seed is fixed.
- **Method:** medians of 3 Studio runs, each the median of 3 interleaved rounds with the order
  rotated.
- **Columns:**
  - **build:** the full-map `NavMesh.Build`, which is the one-off load cost;
  - **tris** (triangles) and **verts** (vertices): the mesh size, which drives search and
    memory;
  - **tile:** the one-tile rebuild proxy. It is a `Build` of one tile's worth of the same
    map: the walkable tile square plus the obstacles centred in it. The median is over up to
    16 tiles per round. This is roughly what `Update` redoes per dirty tile, without the
    clearance recompute (P4).
- **Cross-check:** the triangle and vertex counts are identical in Studio and in the Lune gauge.

| TileSize (studs) | build ms | tris | verts | tiles | tile ms | build spread (per run) |
|---|---|---|---|---|---|---|
| 8 | 849 | 7,823 (+91%) | 5,898 | 1,024 | 0.24 | 849/830/850 |
| 16 | 470 | 5,477 (+34%) | 4,292 | 256 | 0.80 | 470/449/479 |
| 32 | 324 | 4,605 (+12%) | 3,628 | 64 | 1.90 | 329/320/324 |
| 64 | 281 | 4,255 (+4%) | 3,359 | 16 | 5.92 | 283/278/281 |
| 128 | 265 | 4,094 (base) | 3,220 | 4 | 29.34 | 265/251/265 |

**Reading:**
- **Tile borders cost triangles.** Every border splits the triangles crossing it, so the mesh
  grows by 91% at 8 studs and 34% at 16. That cost is paid by every search and in memory.
- **Rebuild cost grows faster than the tile area**, about 3x per doubling and 5x from 64 to
  128. Snap rounding is all-pairs within the rebuilt region. At 128 studs, one dirty tile
  (29 ms) blows a 16 ms frame on its own.
- **Build** is dominated by the floor-wide snap rounding (265 ms even with 4 tiles). Small
  tiles add per-tile triangulation overhead on top of that. The floor-wide snap rounding is
  its own perf item: its all-pairs scan is the `ponytail:` ceiling in `Quantize.luau`.
- **Recommendation: 32 studs.** A door-sized obstacle dirties 1-4 tiles, about 2-8 ms per
  `Update`, which fits a frame. It costs 12% more triangles than a single tile. 64 studs suits
  meshes that almost never update (4% overhead, but 6-24 ms per update).

## Not measured (flagged)
- Remote transfer time and payload size per layout (needs a live server/client session).
- Locality on a real CDT's vertex and triangle ordering. The grid mesh has near-ideal locality,
  whereas a real insertion order (even with BRIO/Hilbert sorting) is less regular, which may
  widen the buffer advantage on cache misses. It is worth re-checking once the real triangulator
  exists.
