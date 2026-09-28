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

## Not measured (flagged)
- Remote transfer time and payload size per layout (needs a live server/client session).
- Locality on a real CDT's vertex and triangle ordering. The grid mesh has near-ideal locality,
  whereas a real insertion order (even with BRIO/Hilbert sorting) is less regular, which may
  widen the buffer advantage on cache misses. It is worth re-checking once the real triangulator
  exists.
