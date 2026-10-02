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

## Speed A/B experiments (2026-09-26)
- **Profile first** (`lune run tools/navmesh/bench/profile_build.luau 256 32`): a 256-stud
  Build takes about 306 ms.
  - Snap rounding: 70%. Its hot-pixel routing scan alone is about 180 ms, and the all-pairs
    crossing scan 39 ms.
  - `CDT.Triangulate`: 24%. Within it, the walk is 13 ms and the flood 11 ms.
  - Build's own work: 6%.
  - `Locate` for heights: 1%.
- **Harness:** `python tools/navmesh/bench/ab.py <experiment> --runs 3 --rounds 5`, in
  Studio, with a Lune gauge at `ab_lune.luau`.
  - Core: `AB.luau`, which interleaves and rotates variants, takes best-of-reps within a
    round and the median over rounds, and **fingerprints every variant's output against the
    baseline**.
  - Experiments live in `ab/`, prototypes in `variants/`. Nothing in `lib/` changes until a
    winner is chosen.
  - Every result below had identical output to its baseline.

**1. Snap rounding scans (`ab/snapround`, `variants/SnapRound.luau`).** Crossing candidates
and hot pixels come from grid buckets or an x sweep. ms, speedup in brackets:

| workload | base | grid256 | grid1024 | **grid2048** | grid4096 | sweep+grid1024 | sweep+grid2048 |
|---|---|---|---|---|---|---|---|
| one 32-stud tile | 0.06 | 0.17 | 0.09 | **0.07** | 0.08 | 0.06 | 0.07 |
| map128 | 17.65 | 5.62 (3.1x) | 3.59 (4.9x) | **3.27 (5.4x)** | 3.62 | 3.31 (5.3x) | 3.46 |
| map256 | 230.8 | 24.0 (9.6x) | 9.78 (23.6x) | **8.61 (26.8x)** | 11.47 | 11.09 | 10.39 |
| map512 | 3663 | 156 (23.5x) | 68.5 (53x) | **62.8 (58x)** | 62.8 (58x) | 71.6 (51x) | 70.6 (52x) |

- **Winner on this map: grid buckets of 2048 grid units (8 studs)** for both scans. The cell
  should adapt to the scene, though; see 1b.
- Cells that are too small lose because tile lines span thousands of cells: grid64 was
  slower than the baseline under Lune.
- The sweep never beat the grid.
- One tile costs about 10 µs more, which is noise.

**1b. Does the best cell depend on the scene? Yes (`ab/cellsize`).** Fixed cells were swept
over four contrasting scenes, against a density rule that picks the cell from the input:
`cell = nextPow2(K * sqrt(boundsArea / segmentCount))`, clamped to [64, 32768] grid units.
The sqrt term is the typical spacing between segments. In the table, `+x%` is the gap to
the best cell for that scene; Studio, 3 runs x 5 rounds, identical output everywhere.

| scene | best fixed cell | fixed 8 studs (grid2048) | density K=1 | density K=2 |
|---|---|---|---|---|
| props: 64-stud room, 512 props of 0.3-2 studs | 2 studs: 6.62 ms | 7.99 (+21%) | **6.60 (best)** | 8.20 |
| bench: the TileSize map | 8 studs: 11.25 ms | 11.25 (best) | 12.45 (+11%) | 11.48 (+2%) |
| terrain: 1024 studs of sparse 15-60 stud rocks, TileSize 128 | 32 studs: 5.97 ms | 9.17 (+54%) | 6.19 (+4%) | 6.99 |
| walls: 256 studs of long thin maze walls | 4 studs: 5.86 ms | 7.97 (+36%) | **5.67 (best)** | 7.56 |

- **Why the cell size matters:**
  - Each query visits every cell its bounding box overlaps, so long segments favour big cells.
  - Each cell's items are all checked, so dense scenes favour small cells.
  - The best cell tracks segment spacing, and spans 2 to 32 studs across these scenes.
- **A bad fixed size is costly.** 1-stud cells on sparse terrain are 4x *slower* than no grid
  at all, and 64-stud cells in the props room are 1.6x slower.
- **Winner: the density rule with K = 1.** It is best or within 11% of each scene's best.
  Fixed 8 studs is up to 54% off.

**2. CDT module-boundary calls (`ab/cdt`).** Variants were generated from the shipped
source:
- `CDTLocal`: the Storage accessors as local functions in Triangulator and Classify, which
  the compiler can inline;
- `CDTLocalPred`: that, plus the predicate float filters as local functions;
- `CDTInline`: that, plus hand-written buffer reads in the walk and legalize loops.

| workload | base | local | local+pred | inline |
|---|---|---|---|---|
| tiles256 (every real tile input) | 74.8 | 56.1 (1.3x) | 55.7 (1.3x) | 52.7 (1.4x) |
| tiles512 | 424.7 | 272.8 (1.6x) | 270.1 (1.6x) | 253.6 (1.7x) |
| floor256 (one large CDT) | 54.1 | 32.8 (1.6x) | 32.3 (1.7x) | 33.2 (1.6x) |

- **Winner: `local`.** The compiler's inlining takes nearly all of the gain.
- Hand inlining adds 0-7% for a readability cost.
- Local predicates add nothing measurable.

**3. Local re-snap for `Update` (`ab/localsnap`, prototype for ticket 18).**
- **Setup:** a door across a tile line on the 256-stud floor.
- **Timing:**
  - A, re-snapping the whole floor (already using the grid variant): 12.1 ms;
  - B, re-snapping only the dirty tiles: 0.61 ms (20x). The gap grows with floor size.
- **Checks on B, all passing:**
  - no crossings;
  - the outer-border vertices are unchanged, so clean neighbours need no work;
  - removing the door reproduces the baseline exactly (SR14);
  - B equals A inside the dirty region.
- **Negative control:** a region too narrow to hold the door's tile crossing breaks the
  border check. The SR13 one-pixel dirty rule is what makes B correct.

**4. Global Lawson pass** (measured earlier): 3.3 ms, 4% of Triangulate. Skipping it gave
identical results on all 94 tile inputs, but it's not worth the risk. **Rejected.**

**Projected Build** (256 map, 32-stud tiles, after 1 and 2 land; measured afterwards: 94 ms): snap rounding about 9 ms
plus Triangulate about 50 ms plus glue about 18 ms, so about 80 ms instead of 306 ms. The
TileSize benchmark should be re-run after they land, because the per-tile costs change.

## Landed (2026-09-26): adaptive snap-round grid, CDT accessor copies
- **`Quantize.SnapRound`:** grid buckets for both scans, sized per call by the density rule
  (K = 1).
  - Studio confirmation, with outputs identical to the variants:
    - map128: 17.6 -> 3.1 ms;
    - map256: 231 -> 8.9 ms;
    - map512: 3663 -> 61 ms;
    - one tile: 0.06 ms either way.
  - The landed rule is best or tied among all fixed cells on every workload.
- **CDT `Triangulator` and `Classify`:** tagged local copies of the Storage accessors
  (`-- inlined: Storage.<fn>`).
  - The strides are literals, so the compiler folds them. A load-time `assert` against the new
    `Storage.Layout` fails loudly on a layout change (negative control: changing
    `Storage.Layout.COORD_BYTES` makes the require fail).
  - Reading the strides from `Storage.Layout` at runtime instead cost 7-19%, as measured.
  - Studio before -> after:
    - tiles256: 76.6 -> 56.5 ms (1.36x);
    - tiles512: 432.9 -> 268.8 ms (1.61x);
    - floor256: 55.2 -> 30.1 ms (1.83x).
- **Build**, bench scene, 32-stud tiles: 324 -> 94 ms (Studio).

## TileSize re-run over scenes (2026-09-26, after the landing)
- **Command:** `python tools/navmesh/bench/tilesize.py --runs 3 --rounds 3`. Scenes are in
  `tools/navmesh/bench/Scenes.luau`.
- **Method:** Studio, medians of 3 runs x 3 rounds.
- **Columns:** `tile` is the one-tile rebuild proxy (see above). `over` is the triangle
  overhead against the scene's largest measured tile size.

| scene | size | build ms | tris | over | tile ms |
|---|---|---|---|---|---|
| props | 4 | 95.8 | 3809 | +37% | 0.60 |
| props | **8** | 53.9 | 3152 | +13% | **0.94** |
| props | 16 | 44.0 | 2939 | +5% | 2.82 |
| props | 32 | 36.1 | 2837 | +2% | 8.87 |
| props | 64 | 36.8 | 2786 | - | 33.4 |
| bench | 8 | 282.9 | 7823 | +91% | 0.27 |
| bench | 16 | 146.5 | 5477 | +34% | 0.77 |
| bench | **32** | 94.4 | 4605 | +12% | **1.69** |
| bench | 64 | 82.8 | 4255 | +4% | 4.48 |
| bench | 128 | 68.5 | 4094 | - | 15.96 |
| terrain | 32 | 207.4 | 3676 | +183% | 0.24 |
| terrain | 64 | 89.2 | 2024 | +56% | 0.48 |
| terrain | 128 | 44.6 | 1493 | +15% | 0.89 |
| terrain | **256** | 31.3 | 1297 | - | **2.17** |
| walls | 8 | 211.8 | 3572 | +497% | 0.20 |
| walls | 16 | 98.3 | 1560 | +161% | 0.23 |
| walls | 32 | 54.9 | 918 | +54% | 0.58 |
| walls | **64** | 35.8 | 692 | +16% | **1.81** |
| walls | 128 | 30.8 | 598 | - | 5.39 |

**Reading: the right TileSize depends on content density too.**
- Rebuild cost scales with the content per tile, and the triangle overhead with the borders
  cut through sparse triangles.
- The bold rows balance the two: about 1-2 ms per rebuilt tile for about 15% more triangles.
  In every scene that is **about 30-40 constraint edges per tile**.
- A fixed 32 studs is fine for `bench`, but costs 8.9 ms per rebuild in `props`, and 3x the
  triangles (and 4.6x the Build time) in `terrain`.
- **Candidate default (awaiting the user's ruling):** per floor,
  `TileSize = nearestPow2(sqrt(36 x floorArea / edgeCount))` studs, clamped to 4-256. An
  explicit `TileSize` overrides it. For these scenes it picks 8 / 32 / 256 / 64, the bold
  rows.

## A* open list (ticket 14 fork, 2026-09-26)
- **Experiments:** `ab/openlist` (the four scenes, random pairs) and `ab/openlist_scale`
  (bench-density floors of 64-1024 studs, 12 corner-to-corner queries in the largest
  connected component). Candidates are in `tools/navmesh/bench/OpenLists.luau`, sharing one
  A* and its scratch. All found identical optimal costs.
- **Chart:** the published "Open List Scaling" page.

Studio, ms per 12 queries (2 of 3 runs; the first hit the run-in-roblox closed-channel
error before measuring):

| floor | peak open | pops/query | lib/heap | no heap | binary | **4-ary** | binary + decrease-key |
|---|---|---|---|---|---|---|---|
| 64 | 19 | 107 | 0.72 | **0.40** | 0.43 | 0.43 | 0.48 |
| 128 | 52 | 868 | 6.00 | 4.89 | 4.05 | **3.87** | 4.22 |
| 256 | 98 | 3188 | 24.36 | 27.22 | 16.48 | **15.68** | 18.26 |
| 512 | 225 | 14908 | 130.69 | 232.59 | 96.56 | **84.03** | 96.00 |
| 1024 | 447 | 59606 | 548.22 | 1711.63 | 391.83 | **372.88** | 422.19 |

- **Why the 4-ary heap wins.** It halves the tree depth: about 0.6 moves per push (binary
  1.25) and 2.3 per pop (3.9), for about 15% more comparisons. In Luau each move is two table
  writes.
- **No decrease-key.** Only 2-7% of pops are stale, and a position index costs more than it
  saves.
- **The no-heap array** is best only below about 25 entries. Its cost per expansion grows with
  the list: 0.31 -> 2.39 µs, 4.6x slower than the 4-ary heap at 447 entries.
- **`lib/heap`** carries a steady 1.5-1.7x overhead: method calls, an index indirection and a
  free-index stack.

**Landed: `lib/navmesh/src/OpenList.luau`**, a 4-ary min-heap as plain module functions on a
state table.
- **Spec (`NavMesh.OpenList.spec`):** a sorted-reference model over 60 seeded interleaved
  push/pop sequences, the node multiset, every depth from 1 to 90 entries, and `Clear`.
  - Negative control: a wrong parent index fails 4 tests.
- **Studio confirmation** (`shipped`, called directly as FindPath will):
  - vs the closure prototype: 0.42 -> 0.29, 3.84 -> 2.54, 15.53 -> 9.94, 81.6 -> 52.6 and
    363 -> 232 ms, 1.46-1.57x faster;
  - 2.3-2.5x faster than `lib/heap`.
  - Identical costs everywhere.

## How FindPath reads the mesh (ticket 14 fork, 2026-09-26)
- **Experiment:** `ab/searchgraph`, on the `openlist_scale` floors with 12 corner-to-corner
  queries each.
- **Setup:** every variant uses the shipped OpenList directly and the same A*; only the graph
  access differs.

Studio, ms per 12 queries, medians of 3 runs x 5 rounds:

| floor | flat (cached graph copy) | storage (accessors, no cache) | storage + cached centroids | buffer + cached centroids | **buffer + {vector} centroids** |
|---|---|---|---|---|---|
| 64 | 0.29 | 0.54 | 0.33 | 0.29 | **0.25** |
| 128 | 2.51 | 4.26 | 2.78 | 2.55 | **2.24** |
| 256 | 10.18 | 18.25 | 11.32 | 10.12 | **8.96** |
| 512 | 54.86 | 89.56 | 60.00 | 54.38 | **49.91** |
| 1024 | 248.0 | 383.7 | 253.5 | 236.7 | **211.0** |

- **Centroids must be precomputed.** Recomputing each centroid from 3 vertices on every visit
  is 1.5-1.9x slower.
- **Neighbours need no copy.** Reading Storage's i32 buffer directly (a tagged inlined copy)
  matches or beats a flat table copy, so the search doesn't have to duplicate the adjacency.
- **Winner: centroids as one {vector} array** (vector-library distances): 1.1-1.2x faster than
  the flat copy.
  - It is a different precision class (f32). Path costs differ from f64 by at most 3.4e-4
    studs, 1.7e-7 relative. That is rounding, not a different route, and it is why the harness
    reports DIFFERENT for this variant only.
- **Implication for ticket 14:** store a per-triangle centroid `vector` in NavMesh Storage.
  - Compute it at Build and on tile rebuild, so there is no separate cache to invalidate on
    `Update`. It costs 16 B per triangle.
  - The search reads neighbours from the buffer and centroids from that array.
- **Superseded (2026-09-27), see the next section:** nodes no longer sit at centroids, so no
  centroid is stored. Reading neighbours straight from the buffer still holds.

## Where A* puts a triangle's node (ticket 14, 2026-09-27)
- **Why:** the first FindPath spec found that nodes at triangle centres bend a clear straight
  line. On the Courtyard, (6, 18) to (6, 29.5) crosses the area-2 patch, whose 2 large triangles
  have centres far off the line. The corridor went round them through small triangles, so the
  path came out 30% long (15.0 vs 11.5 studs).
- **Probe:** `tools/navmesh/bench/nodes_probe.luau` (Lune, `os.clock`; an informal probe, not
  the audited harness). It uses seeded random snapped query pairs, and the three variants share
  the same A*, OpenList and Funnel.
  - `centre`: the node sits at the triangle centre.
  - `entry`: the node sits at the midpoint of the edge the triangle was entered by, as in
    Recast. Its position depends on the parent.
  - `edges`: one node per (triangle, entry edge), at that edge's midpoint. Positions are fixed,
    so this is an exact A* over a fixed graph.
- **Metric:** each funnelled path's length divided by the shortest of the three for the same
  query. The lengths are deterministic; the timings are single-run and indicative only.

| floor (triangles, queries) | centre: mean / worst | **entry**: mean / worst | edges: mean / worst | ms/query centre / entry / edges |
|---|---|---|---|---|
| Courtyard (32, 300) | 1.0162 / 1.561 | **1.0001 / 1.018** | 1.0021 / 1.227 | 0.008 / 0.009 / 0.023 |
| Map64 (244, 200) | 1.0201 / 1.418 | **1.0055 / 1.202** | 1.0104 / 1.255 | 0.037 / 0.044 / 0.125 |
| Map128 (1096, 200) | 1.0356 / 1.260 | **1.0101 / 1.251** | 1.0078 / 1.129 | 0.146 / 0.150 / 0.444 |
| Map256 (4605, 100) | 1.0321 / 1.175 | **1.0066 / 1.113** | 1.0038 / 1.057 | 0.527 / 0.512 / 1.471 |

- **Shipped: `entry`.** It runs at centre's speed and expands fewer triangles (589 vs 820 per
  query on Map256). Its mean excess is 3-5x smaller than centre's, and its worst case is never
  worse.
- **Not shipped: `edges`.** It is about 3x slower, with 2.3x the expansions, and gains only on
  the larger maps.
- **Consequence:** the heuristic is still admissible (SR7), but a node's position depends on its
  parent. The result is therefore the best corridor A* finds, not a proven optimum over a fixed
  graph. The SR7 spec still checks A* against Dijkstra on the Courtyard, plus a cheap-detour
  floor that an unscaled heuristic fails (negative control run).
- **Remaining excess** comes from triangle corridors, not node placement. Up to 11-25% on single
  queries; a real fix would be a corridor-aware refinement, which is not planned.

## Locating the snap candidates (ticket 17, 2026-09-27)
- **Probe:** `tools/navmesh/bench/locate_probe.luau` (Lune, `os.clock`, single runs:
  indicative). 2000 random points per scene, the default snap box (0.5 x 0.5 studs).
- **Parity:** every variant runs the same exact candidate test and picks the same triangle on
  every query.

| scene (triangles, tiles) | scan (was shipped) | tile hash | **tile hash + box reject** | loose-tight double grid | quadtree |
|---|---|---|---|---|---|
| props (3152, 64) | 11.8 us | 9.7 | **6.4** | 4.3 | 153 |
| bench (4605, 64) | 13.0 | 11.2 | **6.1** | 3.2 | 180 |
| terrain (1297, 16) | 13.1 | 11.2 | **5.6** | 1.8 | 144 |
| walls (692, 16) | 6.9 | 6.3 | **4.1** | 2.6 | 79 |
| open16 (2048, 1024) | 27.5 | 0.6 | **1.2** | 5.6 | 34 |

- **The variants:**
  - `scan`: every tile's bounds, then all triangles of the overlapping tiles.
  - `tile hash`: the overlapping tiles by a (floor, i, j) lookup (tiles are origin-aligned).
  - `+ box reject`: each triangle's bounding box is tested before the exact closest-point
    test.
  - `double grid`: `lib/loosetightdoublegrid` over triangle boxes (index build 0.5-8 ms).
  - `quadtree`: `lib/quadtree` over triangle centres, whose search radius must cover the
    largest triangle.
- **Shipped: tile hash + box reject.**
  - It is 2x the old scan on default tiles, and 23x with many small tiles.
  - The double grid saves another 2-4 us per snap. It would cost a package dependency, an index
    to maintain on every `Update`, and non-plain state, and it is 5x slower with many small
    tiles.
  - A snap runs twice per `FindPath`, beside a search of hundreds of microseconds.
- **Not shipped: the quadtree.** It is 10-40x slower, because its query radius has to cover
  the largest triangle.

## Local Update (ticket 22, 2026-09-28)
- **Bench:** `lune run tools/navmesh/bench/update_lune.luau maps|sweep 15` (interpreted Lune,
  `os.clock`). One 4 x 4 crate, added then removed, at side / 2 + (run % 5), the dogfood
  bench's crate.
  - Base is the Update as of c22136d, kept in `tools/navmesh/bench/update_base/`: it rebuilds a
    whole fresh state and measures clearance reach from the obstacle box.
  - Local is the shipped Opt2i: a fresh-state commit with range copies, and incremental
    clearance.
  - Each variant updates its own mesh. The runs are interleaved and the order rotated; there is
    one warm-up. Cells are medians [min-max] over 15 runs, add / remove in ms.
  - The machine was shared (another agent's specs), so read ratios within a row.

**Scenes, default TileSize:**

| scene | cap | TileSize | triangles | tiles | Base add | Base remove | Local add | Local remove |
|---|---|---|---|---|---|---|---|---|
| props | none | default | 3152 | 64 | 26.0 [23.8-31.3] | 27.6 [25.2-30.5] | 20.9 [17.7-22.7] | 21.7 [18.4-25.1] |
| props | 2 | default | 3152 | 64 | 20.0 [15.7-24.9] | 19.8 [16.9-24.1] | 13.7 [11.8-16.8] | 13.2 [10.1-15.5] |
| bench | none | default | 4605 | 64 | 31.4 [24.0-36.7] | 24.4 [21.8-26.3] | 18.9 [10.4-23.7] | 13.0 [9.2-14.2] |
| bench | 2 | default | 4605 | 64 | 21.6 [16.1-25.4] | 16.7 [14.2-18.4] | 10.9 [4.2-13.7] | 5.3 [2.5-7.8] |
| terrain | none | default | 1297 | 16 | 25.7 [14.6-30.7] | 14.7 [11.3-16.4] | 22.5 [11.4-26.3] | 12.9 [7.5-15.7] |
| terrain | 2 | default | 1297 | 16 | 18.3 [8.8-20.9] | 10.2 [7.1-14.1] | 16.5 [5.0-18.2] | 8.2 [3.0-9.4] |
| walls | none | default | 692 | 16 | 45.4 [16.6-49.7] | 17.9 [11.0-18.8] | 46.4 [16.0-51.2] | 18.6 [9.8-19.9] |
| walls | 2 | default | 692 | 16 | 33.4 [7.4-37.2] | 10.3 [4.2-11.8] | 33.8 [6.0-40.9] | 10.2 [2.8-11.7] |

**TileSize sweep, the 256-stud bench map:**

| scene | cap | TileSize | triangles | tiles | Base add | Base remove | Local add | Local remove |
|---|---|---|---|---|---|---|---|---|
| bench | 2 | 64 | 4255 | 16 | 43.0 [20.0-47.6] | 26.5 [15.5-28.9] | 39.1 [11.9-45.7] | 22.3 [7.6-24.0] |
| bench | 2 | 32 | 4605 | 64 | 21.4 [15.3-22.1] | 16.5 [14.6-19.4] | 10.6 [3.8-12.1] | 5.2 [2.3-6.9] |
| bench | 2 | 16 | 5477 | 256 | 20.1 [18.0-22.6] | 17.4 [16.5-19.9] | 3.9 [2.0-5.7] | 2.0 [1.3-2.8] |
| bench | 2 | 8 | 7823 | 1024 | 31.0 [27.3-36.4] | 28.3 [26.2-30.4] | 2.6 [1.5-3.5] | 1.3 [1.1-3.3] |
| bench | 2 | 4 | 14885 | 4068 | 244.9 [235.8-260.3] | 245.8 [230.5-252.0] | 4.3 [3.8-6.4] | 3.1 [2.5-4.7] |
| bench | none | 64 | 4255 | 16 | 50.7 [25.8-54.6] | 32.4 [21.5-36.8] | 45.0 [18.3-51.3] | 28.6 [14.8-31.4] |
| bench | none | 32 | 4605 | 64 | 28.8 [21.5-34.6] | 22.0 [20.0-24.0] | 18.4 [11.1-21.2] | 12.3 [9.0-13.9] |
| bench | none | 16 | 5477 | 256 | 26.3 [22.6-29.5] | 23.9 [22.1-27.4] | 10.7 [7.1-12.7] | 7.5 [6.1-9.9] |
| bench | none | 8 | 7823 | 1024 | 35.3 [33.8-41.4] | 33.8 [30.6-36.8] | 9.7 [7.1-11.1] | 7.3 [6.0-9.1] |
| bench | none | 4 | 14885 | 4068 | 236.8 [230.5-259.1] | 240.1 [223.5-275.5] | 11.8 [9.1-16.2] | 12.1 [10.2-21.0] |

- **What moved:**
  - The O(map) work is gone: the per-tile copy of clean triangles, the floor-wide height scan,
    the wall-grid scan in Clearance, and the reach loop over every triangle.
  - The per-tile source copies are shared rather than copied; they cost 189 ms at 4,068 tiles.
- **What is left** is the dirty tiles' re-snap, triangulation and clearance, which is why
  terrain and walls barely move. Their default tiles are 256 and 64 studs, so the four dirty
  tiles are a quarter of the map.
  - The remaining O(T) is a buffer range copy and one renumbering pass: about 0.9 ms at 7,800
    triangles and 2.5 ms at 15,000 (prototype profile, a loaded machine), or 0.1-0.2 ms per
    1,000 triangles.
  - Uncapped clearance (about 0.3 ms per recomputed triangle) sets the floor of the uncapped
    rows at small tiles.
- **Per-phase profiles and the rejected variants** (Opt1 in-place, Opt2 alone) are on branches
  `proto/local-update` and `proto/local-update-77`. Ruling: review.md, 2026-09-28.

## Shipping a bake in a place (ticket 26, 2026-09-28)
How to hold `NavMesh.Serialize`'s buffer in a place. Measured in Studio (edit mode, plugin
context) by `python tools/navmesh/studio/studio.py ship` (`BakeShip.luau`). Three runs, median
of 7 reps each; the load column gives the range over the runs.
- **Text** is the string's length. **Saved** is the bytes in the binary place format
  (`SerializationService:SerializeInstancesAsync`, the `.rbxm` format a `.rbxl` uses; it
  compresses property data itself).
- **Load** is string to buffer, read from the saved and reloaded copy, before `Deserialize`.
  For a ModuleScript it is `require` of a fresh module (compile and run, with a unique source
  per rep so Studio cannot reuse bytecode).
- Every row round-trips byte for byte through save and load.
- `Deserialize` itself: demo 0.10-0.15 ms, bench 6.9-7.7 ms.

| Option | Demo text (x bake) | Demo saved | Demo load ms | Bench text (x bake) | Bench saved | Bench load ms |
|---|---|---|---|---|---|---|
| Bake bytes | 6,920 | | | 580,187 | | |
| ModuleScript `\xNN` literal (the demo today) | 28,430 (4.11) | 5,862 | 0.19-0.26 | 2,381,213 (4.10) | over the limit | - |
| ModuleScript, printable bytes raw, others `\ddd` | 13,799 (1.99) | 3,999 | 0.07 | 1,284,338 (2.21) | over the limit | - |
| StringValues, base64 (EncodingService) | 9,228 (1.33), 1 value | 4,389 | 0.01 | 773,584 (1.33), 4 values | 403,183 | 1.39-1.89 |
| StringValues, base64 (plain Luau decoder) | same | same | 0.25-0.28 | same | same | 26.8-27.9 |
| **StringValues, zstd then base64 (the recipe)** | **1,468 (0.21), 1 value** | **2,346** | **0.01** | **227,232 (0.39), 2 values** | **229,020** | **1.36-1.67** |
| String attribute, raw bytes | 6,920 (1.00) | 3,395 | 0.00 | 580,187 (1.00) | 263,008 | 0.15-0.19 |
| String attribute, zstd bytes | 1,101 (0.16) | 1,649 | 0.01 | 170,424 (0.29) | 171,636 | 0.80-0.88 |

Compressing (bake time only, zstd level 19): demo 1.7-1.8 ms, bench 95-104 ms.

**Limits found (probes in the same script):**
- A script cannot set `StringValue.Value` or `ModuleScript.Source` to 200,000 characters or
  more ("Provided string length (200000) is greater than or equal to max length (200000)");
  199,999 works and survives a save. So the bench map's ModuleScript literal cannot even be
  written from Studio. A Rojo-built place is not limited: a 773,584-character `.txt`
  StringValue loaded whole.
- Attributes reject a buffer ("buffer is not a supported attribute type"). A string attribute
  holds any bytes, and they survive save and load.
- `BinaryStringValue.Value` is not scriptable.
- `EncodingService` has `Base64Encode`/`Base64Decode` and zstd `CompressBuffer`/
  `DecompressBuffer`. Lune 0.10.4 has neither base64 nor a Roblox-compatible zstd: its zstd
  frames omit the content size, and `DecompressBuffer` fails on them ("decompression failed").
  Lune's `@lune/roblox` also refuses a non-UTF-8 string attribute, so a file pipeline can only
  write text: plain base64.

**Why the recipe is zstd plus base64 in StringValues, not the fastest row:**
- The raw-bytes attribute loads fastest (0.2 ms against 1.4-1.7 ms at the bench size), but
  only Studio can write it (not Rojo or Lune), and attributes have replication caps under
  next-generation replication (a 1,024-byte attribute payload per instance, and 50-character
  strings, per DevForum reports; not measured here). The load time is small either way next to
  `Deserialize`'s 7 ms.
- StringValues can be written both from Studio (`NavMeshEditor:SaveBake`) and from files
  (`.txt` under Rojo). One loader reads both, because it checks for the zstd frame magic.
- zstd cuts the bench text from 4 values to 2 and the saved place data from 403 KB to 229 KB,
  and loads no slower.
- Not measured: replicating a large StringValue or attribute to a client, which needs a live
  server and client session.
## Bake format v3 and Update from authored rings (Track B, 2026-09-28)
- **Bench:** `tools/navmesh/bench/zz_v3_cost.luau` (scratch, not committed). One 4 x 4 crate is
  added then removed, `MaxAgentRadius` 2, medians of 15 interleaved runs, in ms. Old =
  feat/navmesh before B1. A = authored rings plus per-tile snapped sources (verbatim remove).
  B = rings only (shipped).

| scene | TileSize | tris | tiles | bake KB (A) | tile sources KB | added rings KB | Old add | A add | B add | Old remove | A remove | B remove |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| props | default | 3152 | 64 | 412 | 102 | 40.0 | 13.7 | 12.2 | 12.3 | 12.7 | 13.3 | 14.6 |
| bench | default | 4605 | 64 | 623 | 171 | 56.2 | 10.8 | 8.0 | 7.4 | 5.4 | 6.0 | 6.8 |
| bench | 8 | 7823 | 1024 | 1307 | 543 | 56.2 | 2.5 | 2.3 | 2.5 | 1.5 | 1.6 | 2.2 |
| terrain | default | 1297 | 16 | 198 | 64 | 20.5 | 16.3 | 10.6 | 10.9 | 8.4 | 7.9 | 10.1 |
| terrain | 8 | 28912 | 13685 | 6717 | 3717 | 20.5 | 7.9 | 7.7 | 8.0 | 7.0 | 7.2 | 7.0 |
| walls | default | 692 | 16 | 156 | 81 | 12.5 | 34.2 | 15.2 | 15.1 | 10.1 | 10.0 | 13.6 |
| walls | 8 | 3572 | 1024 | 806 | 447 | 12.5 | 2.7 | 2.3 | 2.3 | 1.5 | 1.6 | 1.6 |

- **Bake size:** B's bake is A's minus the tile sources, 25-55% smaller than A's. The "Shipping a bake" sizes above were measured on v2 bakes; v3 bakes of the same levels are smaller. The v3 section
  headers add 6 bytes each.
- **Update:**
  - Adding an obstacle was never slower than Old; walls at the default tile size dropped from
    34 to 15 ms. Only the tile lines bounding the dirty tiles are laid. Laying them all cost
    51 ms at terrain/8, because the walkable outline spans the floor.
  - Removing one costs up to +3.6 ms (walls at the default tile size).
- **Huge rings** (a walkable outline of n points, a crate near it, TileSize 8 / 32):
  - Old, A and B are within noise of each other at every n: 64 points, 18 / 12 ms;
    2,048 points, 1.6 s / 5.0 s to add.
  - Clearance dominates. A reviewer's profile at 512 points put 270 ms of a 275 ms remove in
    `Clearance.Refresh` and 1-2 ms in snapping.
- **Non-planar huge rings:**
  - Creases are now picked per segment: at 8,192 points, `TileInputs` fell from 663 to 21 ms
    (32,768 points: 4,325 to 100 ms).
  - Ring surfaces are cached per mesh in memory; they cost 158 ms per Update at 8,192 points
    before.

## Ticket 27: radius inside the end triangles (2026-09-28)
- **Bench:** `tools/navmesh/bench/findpath_radius_cost.luau`. 400 random queries per
  scene, radius 0.3-2, 7 interleaved passes, median ms per 400.

| scene | TileSize | Old | New | ratio |
|---|---|---|---|---|
| props | default | 39.5 | 51.9 | 1.31 |
| props | 64 | 190.5 | 210.9 | 1.11 |
| bench | default | 88.2 | 97.3 | 1.10 |
| bench | 64 | 95.7 | 103.3 | 1.08 |
| terrain | default | 21.0 | 27.2 | 1.30 |
| terrain | 64 | 23.4 | 27.1 | 1.16 |
| walls | default | 20.5 | 28.5 | 1.39 |
| walls | 64 | 19.3 | 28.5 | 1.48 |

- **Why:** the check runs for the start and goal triangles only. The 15-40 us per `FindPath`
  goes on gathering the walls within r (13-33 us per call); a clear straight line from the end
  to the edge usually exits early.
- **Optimizations kept:**
  - a box pre-test in `nearWalls`, which is exact, so Build's widths are unchanged;
  - `segSeg >= 2r` rejects a link before its exact cost;
  - components are grown only from walls that touch the boundary;
  - a per-mesh memo of the last triangle's walls, dropped by `Refresh`.
- **Without them:** 163 us per call on props.

## E3: radius FindPath with links (Track E, 2026-10-01)
`lune run tools/navmesh/bench/findpath_links_cost.luau` (against `lib/navmesh/src_old`, the
sources before E3). Random links between on-mesh points, two in three bidirectional; 400 random
pairs, median of 7 passes after a warm-up. ms per 400 queries, old / new:

| scene | links | radius 0 | radius 0.3-2 per query | radius 1 |
|---|---|---|---|---|
| props (64) | 0 | 31.5 / 29.6 | 85.2 / 53.0 | 71.8 / 42.0 |
| props | 100 | 32.4 / 32.3 | 110.3 / 198.8 (1.8x) | 125.9 / 102.9 |
| props | 1,000 | 47.4 / 48.4 | 141.8 / 2,457 (17x) | 155.1 / 215.7 (1.4x) |
| bench (256) | 0 | 33.3 / 32.9 | 81.4 / 76.6 | 79.1 / 72.4 |
| bench | 100 | 34.4 / 33.5 | 71.2 / 76.9 | 69.2 / 64.2 |
| bench | 1,000 | 48.2 / 47.5 | 97.3 / 254.7 (2.6x) | 85.7 / 93.8 |

- Each link landing is a node with a barrier test or two (7-13 us cold). A radius drawn per
  query keeps them cold; at one radius they are remembered with each triangle's walls (per
  triangle and radius, until the walls change). Details and the Partial / Success split in ticket 27, "Link and
  seam entries".
- Before the pair-free `Separated` and the memo, props with 1,000 links ran 14,400 ms (103x).

## Track G: path output (2026-10-01)
The full tables are in the tickets; this is the index.
- **Door repaths with `FirstAffectedSegment`** (ticket 28), for 19 door toggles:
  - with the added footprints (ruled): 43 at the default TileSize and 34 at 8;
  - with changed regions: 121 / 72 / 59 / 44 at the default TileSize / 16 / 8 / 4;
  - with `IsPathValid` polling: 118 / 77 / 75 / 64.
  - At the default each floor is one tile, so every region is the whole floor. A tighter region
    (changed triangles only) gave 100 at the default and no change at 16, 8 or 4.
  - The check costs 1.5-2.6 us per NPC.
- **The drape** (ticket 25, `tools/navmesh/bench/path_shape.luau`): FindPath time within
  ±5% noise on flat maps (+13% on a hilly ring). Lerp drift drops from 3.2-3.7 studs to at most
  0.0099. A `SamplePath` helper costs 2-10x a FindPath at 1-stud spacing and still drifts 0.12-0.16.
- **Path length against the exact shortest path** (ticket 25, branch `proto/g-areabend`):
  p95 1.074 and max 2.33 with midpoint nodes, against 1.0036 and 1.23 with heron nodes (built,
  for uniform costs). FindPath with heron: props 150 to 72 us at r 0, bench 207 to 100, walls
  65 to 67; at r 1, 181 to 187, 242 to 155 and 85 to 84 (ticket 25's heron section).
- **Bisector funnel** (ticket 25, branch `proto/g-bisector`): see ticket 25's "Measured"
  section.
- **Partial ends** (ticket 27's G3 section, `tools/navmesh/bench/partial_end.luau`): ends a
  flood proves unreachable drop from 216/405 to 90/405 on the many-slab rooms. Partial FindPath
  there goes from 30 to 56-61 us mean.

## Large worlds, 1-4 km (ticket 31, 2026-10-01)
**Question:** how do Build, the bake and queries scale on 1-4 km maps? The answer feeds the D6
ruling ("Measure first") on region bakes.

**Bench:**
- `lune run tools/navmesh/bench/large_world.luau sides=1024,2048,4096 runs=3 [maps=...] [tiles=...] bakes`
  measures in interpreted Lune with `os.clock`.
- The maps are in `LargeMaps.luau`; everything after Build is measured from the bake by
  `LargeWorld.luau`.
- Studio: `python tools/navmesh/bench/large_world.py --runs 3` loads the 4 km bakes as base64
  StringValues.

**Maps** (seeded, the same density at every size):
- **city:** a street grid with a 96-stud pitch and 16-stud streets, and four building lots per
  block. Each building footprint is an obstacle.
  - One lot in 16 holds a two-storey building: a ramp floor and a roof floor at y = 12, with
    two seams.
  - At 4 km that makes 862 seams and 863 floors.
- **open:** one floor with props of 1-4 studs, randomly rotated, one per 400 square studs.
  That is 42k obstacles at 4 km.
- **terrain:** what a terrain adapter would emit.
  - A heightfield lattice of 32-stud cells, rotated 3 degrees, split into two planar triangle
    rings per cell, with cliffs (cells steeper than 1 in 2) left out.
  - Rocks are obstacles, one per 2,000 square studs.
  - That is 7.7k walkable rings at 2 km and 31k at 4 km.

**Method:**
- Every desc sets `MaxAgentRadius` 2, and every query uses `AgentRadius` 1.
- Each cell (map, side, TileSize) is measured once per run, with the cell order rotated each
  run. Cells are the median [min-max] over 3 runs.
- 4 km terrain ran once, at the default TileSize only. Its Build is quadratic (below).
- The machine was shared with Track G's specs and oracles, and with the H2 dogfood agent. An
  earlier, more loaded sweep measured Builds up to 2x slower (open 2 km: 5.9 s against 3.0 s),
  so read ratios within a row.
- **TileSize:** the default resolves to 128 studs on city and 64 on the others, at every side.
  Each map also gets two other sizes.
- **Heap:** neither runtime lets a script force a collection.
  - `LargeWorld`'s settled heap churns short-lived garbage until the count stops falling.
  - Check: a 10 MB buffer reads 10.2-10.3 MB, and the same 1 km mesh reads 3.8-4.8 MB over
    six loads, so read it as about ±15%.
- **FindPath:** 30 seeded pairs, at least side / 2 apart in plan, each run with no budget and
  then with `MaxExpansions` 5,000. Hits counts the `Budget` results.
- **Cold** is the first radius `FindPath` (or the first `Update`, one 4 x 4 crate) on a fresh
  `Deserialize`. **Warm** is the same `FindPath` after the 60 others, and the median of 10
  later crate adds and removes.

**Size and load** (Lune; Build in seconds, bake and zstd in MB, zstd at level 19):

| map | side | TileSize | triangles | tiles | Build s | bake MB | zstd MB | Deserialize ms | heap MB |
|---|---|---|---|---|---|---|---|---|---|
| city | 1024 | default (128) | 3,179 | 155 | 0.12 [0.11-0.12] | 0.31 | 0.05 | 2.7 [2.6-2.8] | 0.7 |
| city | 1024 | 32 | 5,561 | 1,127 | 0.27 [0.25-0.31] | 0.55 | 0.08 | 4.4 [4.3-4.8] | 1.4 |
| city | 1024 | 64 | 3,773 | 333 | 0.15 [0.15-0.15] | 0.37 | 0.06 | 3.0 [2.9-3.3] | 0.7 |
| city | 2048 | default (128) | 13,840 | 635 | 0.53 [0.50-0.60] | 1.34 | 0.20 | 11.0 [10.9-11.3] | 2.8 |
| city | 2048 | 32 | 23,662 | 4,546 | 1.11 [1.09-1.13] | 2.32 | 0.31 | 18.4 [17.9-18.8] | 5.4 |
| city | 2048 | 64 | 16,376 | 1,340 | 0.66 [0.66-0.66] | 1.58 | 0.24 | 12.8 [12.4-13.4] | 2.9 |
| city | 4096 | default (128) | 55,409 | 2,464 | 2.25 [2.19-2.27] | 5.35 | 0.81 | 46.9 [45.7-48.8] | 10.9 |
| city | 4096 | 32 | 94,545 | 18,149 | 4.82 [4.70-4.83] | 9.26 | 1.23 | 78.4 [76.4-81.5] | 22.5 |
| city | 4096 | 64 | 65,345 | 5,300 | 2.80 [2.79-2.95] | 6.30 | 0.93 | 52.8 [51.5-53.3] | 11.5 |
| open | 1024 | default (64) | 16,543 | 256 | 0.75 [0.73-0.75] | 1.57 | 0.31 | 12.4 [12.0-13.1] | 4.2 |
| open | 1024 | 32 | 18,576 | 1,024 | 0.74 [0.73-0.75] | 1.76 | 0.34 | 13.3 [13.3-14.4] | 4.1 |
| open | 1024 | 128 | 15,918 | 64 | 0.74 [0.74-0.74] | 1.51 | 0.30 | 12.3 [11.2-12.4] | 2.6 |
| open | 2048 | default (64) | 66,407 | 1,024 | 3.00 [2.97-3.01] | 6.28 | 1.21 | 52.4 [52.0-57.9] | 16.2 |
| open | 2048 | 32 | 74,456 | 4,096 | 3.09 [3.06-3.14] | 7.06 | 1.33 | 61.0 [58.6-63.5] | 16.5 |
| open | 2048 | 128 | 63,811 | 256 | 3.06 [3.03-3.11] | 6.04 | 1.19 | 49.3 [46.6-50.4] | 10.4 |
| open | 4096 | default (64) | 265,434 | 4,096 | 13.0 [12.8-13.6] | 25.1 | 4.88 | 694 [658-698] | 66.2 |
| open | 4096 | 32 | 297,861 | 16,384 | 13.2 [13.0-13.3] | 28.3 | 5.36 | 690 [685-711] | 68.8 |
| open | 4096 | 128 | 255,454 | 1,024 | 13.1 [12.9-13.8] | 24.2 | 4.73 | 657 [639-699] | 41.8 |
| terrain | 1024 | default (64) | 10,998 | 256 | 3.28 [3.23-3.50] | 1.08 | 0.22 | 9.2 [8.3-9.3] | 2.3 |
| terrain | 1024 | 32 | 16,573 | 1,024 | 5.17 [5.03-5.29] | 1.56 | 0.29 | 13.0 [11.7-13.9] | 4.1 |
| terrain | 1024 | 128 | 8,564 | 64 | 2.62 [2.60-2.69] | 0.88 | 0.18 | 8.4 [7.0-8.8] | 2.2 |
| terrain | 2048 | default (64) | 45,868 | 1,024 | 62.8 [62.8-77.6] | 4.49 | 0.91 | 40.8 [36.3-41.4] | 9.4 |
| terrain | 2048 | 32 | 68,672 | 4,096 | 99.8 [96.4-104.8] | 6.44 | 1.23 | 56.5 [54.1-56.7] | 16.4 |
| terrain | 2048 | 128 | 35,888 | 256 | 51.6 [48.7-59.3] | 3.66 | 0.76 | 31.5 [31.5-41.5] | 9.1 |
| terrain | 4096 | default (64) | 187,167 | 4,096 | 2,082 (one run) | 18.3 | 3.65 | 495 | 37.8 |

**Queries** (Lune, ms):

| map | side | TileSize | FindPath p50 | p95 | Budget p50 | p95 | Budget hits | cold FindPath | warm | cold Update | Update p50 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| city | 1024 | default | 0.28 | 0.56 | 0.28 | 0.48 | 0/30 | 2.5 [2.5-3.6] | 0.4 | 5.8 [5.6-6.1] | 2.6 |
| city | 1024 | 32 | 0.45 | 0.97 | 0.46 | 0.97 | 0/30 | 4.1 [4.0-4.1] | 1.0 | 6.2 [6.2-6.8] | 1.9 [1.5-2.7] |
| city | 1024 | 64 | 0.30 | 0.69 | 0.29 | 0.79 | 0/30 | 2.7 [2.7-3.1] | 0.4 | 5.5 [5.5-5.7] | 2.2 [2.1-2.3] |
| city | 2048 | default | 1.04 | 2.16 | 0.98 | 2.36 | 2/30 | 10.7 [10.6-12.4] | 0.8 | 17.9 [15.0-19.1] | 5.5 [5.4-5.6] |
| city | 2048 | 32 | 1.72 | 4.08 | 1.47 | 2.72 | 11/30 | 17.4 [17.4-17.5] | 4.0 | 23.3 [22.2-25.0] | 6.7 [6.3-7.4] |
| city | 2048 | 64 | 1.35 | 3.37 | 1.31 | 2.78 | 9/30 | 11.9 [11.3-12.7] | 1.5 | 17.1 [15.3-18.2] | 4.8 [4.3-5.0] |
| city | 4096 | default | 5.20 | 9.99 | 2.64 | 3.05 | 28/30 | 54.5 [50.5-55.3] | 6.0 | 69.7 [68.5-77.8] | 18.1 [15.1-19.4] |
| city | 4096 | 32 | 8.45 | 19.46 | 2.91 | 3.33 | 28/30 | 71.4 [70.2-77.1] | 14.0 | 100.5 [94.7-102.8] | 25.6 [23.6-30.4] |
| city | 4096 | 64 | 4.96 | 11.83 | 2.83 | 3.32 | 27/30 | 61.9 [52.1-63.8] | 6.6 | 81.4 [70.0-90.5] | 19.9 [19.2-20.4] |
| open | 1024 | default | 1.27 | 2.01 | 1.17 | 2.35 | 3/30 | 9.1 [9.1-10.8] | 1.3 | 17.1 [16.7-17.3] | 6.5 [5.9-7.3] |
| open | 1024 | 32 | 1.04 | 2.09 | 1.03 | 2.38 | 2/30 | 10.3 [9.9-12.4] | 1.5 | 15.9 [14.9-19.4] | 4.4 [4.0-4.9] |
| open | 1024 | 128 | 1.03 | 2.22 | 0.99 | 2.42 | 2/30 | 8.4 [7.9-8.9] | 1.2 | 23.5 [22.8-23.6] | 13.7 [13.7-14.7] |
| open | 2048 | default | 4.54 | 7.37 | 2.49 | 2.98 | 30/30 | 40.1 [37.1-45.2] | 6.2 | 58.1 [56.2-59.6] | 16.6 [16.4-18.6] |
| open | 2048 | 32 | 5.13 | 8.21 | 2.56 | 3.42 | 29/30 | 37.6 [35.9-43.3] | 2.8 | 64.8 [63.9-70.4] | 19.7 [18.2-20.6] |
| open | 2048 | 128 | 3.81 | 9.75 | 2.50 | 3.12 | 29/30 | 37.5 [37.1-38.6] | 7.9 | 57.9 [55.4-60.5] | 21.1 [19.5-21.6] |
| open | 4096 | default | 18.16 | 37.23 | 2.82 | 3.62 | 30/30 | 129.8 [126.2-146.1] | 21.9 | 249.9 [240.7-284.0] | 72.9 [65.4-73.5] |
| open | 4096 | 32 | 19.04 | 34.70 | 2.86 | 3.76 | 30/30 | 192.2 [167.9-211.0] | 24.8 | 268.6 [264.8-292.2] | 68.9 [67.0-72.9] |
| open | 4096 | 128 | 18.88 | 36.71 | 2.87 | 3.88 | 30/30 | 128.2 [127.7-157.0] | 19.5 | 242.0 [240.9-251.3] | 72.9 [68.7-77.5] |
| terrain | 1024 | default | 0.66 | 1.83 | 0.64 | 1.70 | 0/30 | 4.4 [4.2-5.1] | 0.3 | 57.4 [56.6-59.6] | 15.6 [15.3-16.2] |
| terrain | 1024 | 32 | 0.85 | 2.34 | 0.81 | 2.66 | 2/30 | 6.8 [6.6-7.0] | 0.6 | 55.2 [55.1-61.2] | 12.9 [12.3-13.6] |
| terrain | 1024 | 128 | 0.48 | 1.44 | 0.44 | 0.98 | 0/30 | 4.2 [3.7-5.1] | 0.3 | 87.5 [83.9-90.7] | 46.8 [45.8-48.2] |
| terrain | 2048 | default | 3.31 | 8.86 | 2.63 | 3.48 | 24/30 | 23.7 [19.7-27.3] | 1.8 | 263.8 [263.5-285.1] | 80.4 [79.4-90.6] |
| terrain | 2048 | 32 | 3.14 | 8.30 | 2.75 | 3.78 | 24/30 | 27.0 [26.6-28.4] | 3.0 | 227.5 [220.1-230.7] | 37.7 [36.4-47.5] |
| terrain | 2048 | 128 | 1.65 | 8.54 | 1.68 | 2.89 | 11/30 | 19.2 [18.2-21.4] | 2.5 | 383.2 [365.5-398.9] | 211.0 [194.0-226.4] |
| terrain | 4096 | default | 11.53 | 29.02 | 2.87 | 3.52 | 30/30 | 96.9 | 12.7 | 1,292 | 583 |

The FindPath and Budget columns are medians over runs. Each run's values are in the `[R]` lines
the bench prints.

**Studio** (the 4 km bakes, `large_world.py --runs 3`, edit mode, median [min-max]):

| map | bake MB | Deserialize ms | heap MB | FindPath p50 | p95 | Budget p50 | cold FindPath | warm | cold Update | Update p50 |
|---|---|---|---|---|---|---|---|---|---|---|
| city | 5.35 | 89.8 [54.5-130.7] | 10.9 [10.7-10.9] | 5.34 | 9.44 | 2.54 | 47.6 [44.4-53.9] | 6.0 | 64.5 [61.2-68.2] | 19.9 [19.5-20.4] |
| open | 25.1 | 704 [696-768] | 66.4 [65.1-68.0] | 18.97 | 37.62 | 2.68 | 148.3 [129.3-161.2] | 21.7 | 220.6 [207.4-245.4] | 75.2 [72.6-77.5] |
| terrain | 18.3 | 543 [502-555] | 37.3 [36.8-44.8] | 12.70 | 30.55 | 2.78 | 72.1 [63.6-77.3] | 12.5 | 1,237 [1,212-1,248] | 501 [497-522] |

- Studio runs at about Lune's speed here, within 15% on every column except city's noisy
  `Deserialize`.
- An earlier three-run Studio pass, on city and open only, agreed: open `Deserialize` took
  724 [712-793] ms and held 65.1 MB.
- That earlier pass read city's heap as 16.7 [10.4-17.3] MB. Studio's heap gauge includes the
  rest of its Luau VM, so small meshes read noisily. Loading a 4 km open bake holds about
  65 MB in both runtimes.

**Where the time goes** (each line has its script):
- **Build is O(triangles x walkable rings) on a floor** (`rings_repro.luau`,
  `profile_build.luau 1024 default terrain`).
  - Build asks every walkable ring's surface for each kept triangle's heights, with one
    `CDT.Locate` per ring. At 1 km terrain that is 21M Locates, 80% of Build.
  - On an n x n grid of 8-stud squares, Build takes 13, 68, 593 and 7,655 ms at 64, 256,
    1,024 and 4,096 rings.
  - `Update` shares the cost: one crate's `Update` takes 6.9, 16, 56 and 330 ms on those
    meshes.
  - This is the whole terrain story: Build takes 3 s at 1 km, 63-100 s at 2 km and
    35 minutes at 4 km (2,082 s, one run). Open and city stay linear: about 50 us per triangle on open, 40
    on city.
- **Deserialize runs at 0.8-0.9 us per triangle**, except on the 4 km open map, where it takes
  2.8 us (`deserialize_profile.luau`).
  - That bake spends 520 of its 731 ms in `Storage.SetFloorSources`, which appends 42k rings
    with `table.move`.
  - Appending with `table.move` past the array part is quadratic in Luau
    (`tablemove_repro.luau`: 80k four-point rings take 680-740 ms, against 5 ms by index).
  - The memcpy floor for the same bake is 6 ms, and `Connect` takes 1 ms.
- **A warm Update grows with the map, not the change** (`update_profile.luau`; one crate on
  the open map):

| side | triangles | rings | Update ms | ring scan | clean-tile copy | TileInputs + triangulate + Refresh | rest |
|---|---|---|---|---|---|---|---|
| 1024 | 16,543 | 2,622 | 5.6 | 1.5 | 1.6 | 1.3 | 1.2 |
| 2048 | 66,407 | 10,486 | 18.8 | 8.4 | 5.3 | 2.5 | 2.6 |
| 4096 | 265,434 | 41,944 | 66.9 | 44.2 | 18.6 | 1.9 | 2.2 |

  - The **ring scan** is `Tiles.reSnap`, which takes the bounds of every authored ring on the
    floor to find those near the dirty tiles.
  - The **clean-tile copy** is the O(T) copy that ticket 22 deferred (Opt1).
  - On the 4 km city, `Build.Internal.Connect` adds 7.2 ms per `Update`, because it re-joins
    all 862 seams.
  - On terrain the ring term dominates instead. `TriangulateTile` takes 38 ms of a 43 ms
    `Update` at 1 km, 60 of 74 at 2 km and 436 of 477 at 4 km
    (`update_profile.luau terrain 3`; its crate falls elsewhere than LargeWorld's).
- **The load spike** (known-gaps.md):
  - The first radius `FindPath` after `Deserialize` costs 6-9x a warm one: 130 against 22 ms
    on the 4 km open map.
  - The first `Update` costs about 3.4x: 250 against 73 ms.
- **Heap:**
  - A loaded mesh holds 2-2.6x its bake.
  - The triangle buffers keep their doubling capacity, so up to half of them is slack
    (`heap_fields.luau open-4096`: 182 bytes per triangle allocated, where the data needs 92).
  - Hence the 4 km open map's 66 MB at the default TileSize (265k triangles, capacity 524k)
    against 42 MB at TileSize 128 (255k triangles, capacity 262k).
  - The f64 widths are 52% of what the buffers allocate.
- **The bake** (`bake_sections.luau 4096`):
  - Triangles are 76-78% of it, at 77 bytes each: 12 vertex, 12 neighbour, 4 area, 1 open and
    48 width bytes.
  - Authored rings are 12%, and vertices 9%.
  - zstd already shrinks the bake 5-7x. Narrower widths save little on top of it.

| bake | triangle section | f64 widths (today) | f32 widths | u16 widths (1/256 stud, rounded down) |
|---|---|---|---|---|
| open 4 km | raw MB | 19.5 | 13.4 | 10.4 |
| open 4 km | zstd MB | 2.91 | 2.57 | 2.38 |
| city 4 km | raw MB | 4.08 | 2.81 | 2.18 |
| city 4 km | zstd MB | 0.52 | 0.46 | 0.45 |

- **MaxExpansions 5,000** keeps a cross-map `FindPath` to about 3-5 ms (p95) at any size.
  - But it truncates: 27-30 of 30 cross-map queries end `Budget` on the 2 km open map and on
    every 4 km map.
  - 5,000 expansions cover about 1-2 km of open ground.
- **TileSize:**
  - 32 costs 12-75% more triangles and bake than the default, and up to 2.3x the Build on
    city.
  - 128 on open keeps the bake but costs 2.1x per warm `Update` at 1 km (13.7 against 6.5
    ms). Its tile rebuild is the bigger part there.
  - At 4 km the O(map) terms swamp the TileSize differences.

**Reading for D6:**
- **Up to 2 km, the bake and the load are fine on every map tried.**
  - City: 1.3 MB (0.2 MB zstd), 11 ms to load and 3 MB of heap.
  - Open: 6.3 MB (1.2 MB zstd), 52 ms to load and 16 MB of heap.
  - Terrain: 4.5 MB (0.9 MB zstd), 41 ms to load and 9 MB of heap.
  - But terrain's Build (63 s) and warm `Update` (80 ms) at 2 km are already not fine. That
    is the ring term, not size.
- **At 4 km the open map is the problem:**
  - a 25 MB bake (4.9 MB zstd);
  - a 0.7 s `Deserialize` in Studio, on the client's main thread;
  - 66 MB of heap;
  - a 67-73 ms warm `Update`.
  - 4 km terrain is worse on time but not on size: a 35-minute Build and a 583 ms warm
    `Update`, with an 18 MB bake (3.7 MB zstd), a 0.5 s load and 38 MB of heap.
- **Most of that is not size itself:**
  - The `table.move` appends cost 520 ms of the load.
  - Buffer slack is a third of the heap.
  - The ring scan and the O(T) copy are 63 of 67 ms of an `Update`.
- **Measured from the parts** (not built), the cheap fixes would give about:
  - `Deserialize` 0.24 s;
  - heap about 43 MB, or about 37 MB with f32 widths in memory;
  - a warm `Update` under 25 ms with the ring index alone, and about 5 ms with Opt1 too.
- **Terrain-like input needs the surface index before anything else.** No region scheme helps
  a Build that is quadratic within a floor.

## Ticket 30: FindPath with many links (Track E, 2026-10-01)
`lune run tools/navmesh/bench/link_scale.luau`. Random links between on-mesh points on each
scene, dearer than walking (Cost 1-2x the distance, areas 1-4); 400 random pairs at r 0, median
of 7 passes. "HeuristicScale" is 1,000 calls with `AreaCosts = { [2] = 1.5, [3] = 0.8 }`.

**Before** (the scale looped over every link on every query):

| scene | links | FindPath us | HeuristicScale us |
|---|---|---|---|
| props | 0 / 100 / 1,000 | 76 / 85 / 125 | 0.04 / 4.1 / 44 |
| bench | 0 / 100 / 1,000 | 81 / 123 / 169 | 0.05 / 6.6 / 55 |
| terrain | 0 / 100 / 1,000 | 44 / 68 / 114 | 0.03 / 5.5 / 60 |
| walls | 0 / 100 / 1,000 | 108 / 111 / 170 | 0.05 / 5.4 / 57 |

At 1,000 links the scale was 35-50% of a query. The candidate, the cheapest Cost / length kept
per link area (rebuilt once after any link change), took 0.07-0.11 us and gave the same scale
in all 12 cases. The other candidate in ticket 30, a cache keyed by the `AreaCosts` table, was
not built: it breaks when a caller edits its table in place, and per-area is already O(areas).

**After** (`Storage.LinkPrices`, read by `Search.HeuristicScale`):

| scene | links | FindPath us | HeuristicScale us |
|---|---|---|---|
| props | 0 / 100 / 1,000 | 73 / 80 / 88 | 0.02 / 0.07 / 0.07 |
| bench | 0 / 100 / 1,000 | 87 / 80 / 95 | 0.02 / 0.08 / 0.08 |
| terrain | 0 / 100 / 1,000 | 38 / 41 / 55 | 0.02 / 0.07 / 0.09 |
| walls | 0 / 100 / 1,000 | 78 / 77 / 74 | 0.02 / 0.08 / 0.08 |

What 1,000 links still add (up to 17 us on terrain) is the search expanding the links
themselves. Runs vary by about 10%: other sessions shared the machine.

## Not measured (flagged)
- Remote transfer time and payload size per layout (needs a live server/client session).
- Locality on a real CDT's vertex and triangle ordering. The grid mesh has near-ideal locality,
  whereas a real insertion order (even with BRIO/Hilbert sorting) is less regular, which may
  widen the buffer advantage on cache misses. It is worth re-checking once the real triangulator
  exists.
