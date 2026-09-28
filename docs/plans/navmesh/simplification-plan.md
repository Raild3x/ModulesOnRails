# Plan: geometry simplification for the NavMesh/CDT pipeline

Status: research and plan, 2026-09-28. Nothing in `lib/` changed. The numbers come from scratch
prototypes, listed under "Reproducing" at the end.

The user's idea: "Running a pass on the navmesh/CDT and merging lines that are collinear within
some epsilon... careful on very long lengths since even a single degree on a mile long line
could cause a large deviation. What other similar optimizations could we perform?"

## Summary

**1. The target is the content we are about to get, not the bench maps.**
- On the four bench maps (random boxes) and the demo level, no geometric simplification removes
  more than 3.6% of the triangles. Their rings are already four points, and their union corners
  are real geometry.
- The wins are all on content that a Part adapter (ticket 26) or a terrain adapter will
  produce:
  - **dense rings:** noisy rocks, coastlines, cylinder Parts;
  - **floors authored in pieces:** one walkable ring per floor Part.
- I built one synthetic scene of each kind, `rocks` and `pieces`, next to the bench maps.

**2. Recommended, in order:**
1. **R1: one-sided ring simplification when rings are quantized.** This is the user's idea,
   applied per ring.
   - The tolerance is a distance in studs, never an angle.
   - Walkable rings only shrink, and obstacles only grow.
   - At the proposed default of 1/16 stud on `rocks`:
     - triangles go down 32%;
     - Build goes from 27.3 s to 10.9 s (−60%, median of 3);
     - `FindPath` gets 29% faster;
     - mean path length goes up 0.05%.
   - It removes exactly nothing on box maps.
   - Effort: about 2-3 days, including specs.
2. **R2: dissolve constraint edges that have the same class on both sides**, inside the
   per-tile triangulation.
   - It is exact: no geometric error at all.
   - On a floor authored as 246 overlapping Part pieces, it removes 46% of the triangles and
     halves `FindPath` time.
   - On today's maps it finds nothing to do, and it costs nothing.
   - Effort: about 2-3 days.
3. **R3: path quality at query time, in ticket 25. This one is not geometry.**
   - The "+8% area bend" is not caused by area edges. Removing the areas moves individual paths
     by −20% to +19%, with a mean of +0.0% to +0.2%.
   - The edge-midpoint search picks corridors up to 25% longer than needed, whatever the
     constraints are. Deleting geometry can't fix that.

**3. Skip these:**
- gap closing (morphological opening);
- dropping small obstacles or holes;
- a coarse far-field grid;
- Steiner or hot-pixel removal;
- edge collapse;
- dropping tile lines.

Each either adds geometry, invents walkable space, breaks the `Update` oracle, or measured zero
gain.

Defer convex-polygon search. It halves the search node count, but it conflicts with clearance
stored per triangle.

**4. Four rulings needed.** See "Decisions for the user":
- the default tolerance;
- the API shape;
- whether cracks between Parts may be welded;
- whether R2 lands before the Part adapter.

## What the pipeline allows

These are the facts every candidate is checked against.

**Where a pass can sit.** Build runs these stages, and a pass could sit at any of them:

| Stage | Where | What it sees | Does `Update` run it too? |
|---|---|---|---|
| P0 | the description | authored float rings | no: `AddObstacle` sees one ring |
| P1 | `quantizeRing` | one ring, as grid integers, CCW | yes, through `Internal.QuantizeRing` |
| P2 | floor-wide `Quantize.SnapRound` | all rings, creases, seams and tile lines | only locally (a re-snap of the dirty tiles) |
| P3 | `triangulateTile` | one tile's snapped, clipped fragments, plus the CDT classification | yes, the same function |
| P4 | `Clearance.Compute` | the kept mesh | yes, for dirty tiles plus reach |
| P5 | `Search` / `Funnel` | queries | n/a |

**The oracle decides where cross-ring passes can go.** The oracle is: `Update(add X)` equals
`Build(desc + X)`, including widths (NavMesh.Obstacles spec).
- A pass that looks at several rings can only live in P3. That is the one function Build and
  `Update` both run on identical per-tile input.
- The same pass at P0 or P2 would merge a static obstacle with its neighbours at Build, but
  never with a dynamic one.
- A per-ring pass at P1 is safe, because `AddObstacle` runs the same `QuantizeRing`.

**Tile-border vertices are shared by neighbouring tiles (SR3).** A P3 pass must pin them, or a
rebuilt tile changes its clean neighbour.

**`CDT.Refine` has no target here.**
- NavMesh never calls `CDT.Refine`, and Build errors if the CDT adds a vertex.
- The nearest thing to "Steiner vertices" is snap-rounding hot pixels. On the bench maps, 12-48%
  of kept vertices are hot pixels (walls 48%, terrain 28%, bench 24%, props 12%).
- Those hot pixels are the corners where obstacles overlap, which is real geometry. Pre-unioning
  the obstacles (variant U) turns them into input vertices and leaves the triangle count
  unchanged (props: 3152 → 3150).

**Build time is clearance.** Over the six bench-size scenes (5-round medians):
- clearance is 79-99% of Build;
- triangulation is 0.6-14%, and snap rounding 0.1-4%.

So simplification speeds Build up through the kept triangle count, and more strongly through the
number of wall edges near each triangle, which is what the clearance chain search walks. On
rocks, 32% fewer triangles and 34% fewer wall edges took Build down 60%.

**Tiles are the snap index.**
- With one tile per floor (variant T1), `FindPath` got 2.1-5.6x slower.
- `Snap` hashes tiles, then scans each tile's triangles, so one big tile makes it linear.

**Search nodes sit at edge midpoints, so any mesh change moves individual paths.**
- Removing all areas from bench moved single paths by −7% to +13%, with a mean of +0.2%.
- Path effects below are therefore given as a mean over 200 fixed pairs, with the worst pair
  alongside.

**Serialize v2 stores what a pass would change.** It stores:
- the kept triangles;
- each tile's pre-P3 baseline;
- each obstacle record as its quantized ring.

Either kind of pass then bakes in consistently:
- a P1 pass is baked into the rings and records;
- a P3 pass is baked into the triangles, and re-run from the baseline on `Update`.

A tolerance must still be stored in the bake, so that `AddObstacle` after `Deserialize` applies
the same rule. That makes it a format bump.

## Guarantees (the contract)

| # | Guarantee | Why |
|---|---|---|
| G1 | **Walls only move into free space.** The new kept region ⊆ the old one. Walkable rings shrink and obstacles grow (up to the existing half-pixel snap wobble). | Agents never clip geometry. |
| G2 | **Bounded displacement.** Hausdorff(old kept, new kept) ≤ ε studs, where ε is a distance. | This answers "one degree over a mile" (below). |
| G3 | **Clearance is never over-reported.** Every stored width ≤ its value without the pass, and it drops by at most 2ε. Follows from G1. | The query radius check stays safe. |
| G4 | **Reachability is never invented.** A path exists after the pass only if one existed before, at the same radius. Follows from G1 and G3. | |
| G5 | **Exact passes are exact.** They leave the kept region, each area's region and every wall unchanged, bit for bit in grid units. | R2 |
| G6 | **Pinned features never move:** seam fragments and their ends, tile-border vertices, crease ends, and vertices where 3 or more classes meet. | SR3, seams, SR6 |
| G7 | **`Update` equals a fresh Build**, widths included. | Obstacles spec oracle |
| G8 | **The snap-rounding invariant holds.** The CDT gets only grid points and non-crossing edges, and never adds a vertex. | SR2 guards |

**"One degree over a mile"**, worked through:
- A Roblox mile is about 5,750 studs.
- **Angle bound:** a 1° bend in the middle of a 5,750-stud chain puts the middle vertex about 50
  studs off the straight chord, and an angle tolerance would allow it.
- **Distance bound:** with ε = 1/16 stud, the largest bend allowed is atan(2ε / L):
  - 0.0012° on that 5,750-stud chain;
  - 1.8° on a 4-stud crate edge.
- So the tolerance is ε in studs: the perpendicular distance from every removed vertex to the
  chord that replaces it. For a one-sided chain, that distance is the Hausdorff distance.

## The user's idea: one-sided collinear merging

**Rule.** Walk a ring and replace a run of vertices by a chord from anchor a to anchor b when all
of these hold:
1. **Every removed vertex lies on the permitted side of a→b.** Decided exactly with
   `CDT.Orient2D` on grid integers. With CCW rings, the permitted side follows from G1:
   - an **obstacle** loses only vertices left of the chord (its notches), so it grows;
   - a **walkable ring** loses only vertices right of the chord (its corners), so it shrinks.
2. **Every removed vertex is within ε of the chord.** This test can be approximate: it's a
   tolerance, not topology.
3. **No removed vertex is pinned (G6).** Here that means within ε of one of the floor's seams.
4. **The result passes the existing self-intersection check.** Otherwise the ring is kept as
   authored.

Area rings are not simplified, for two reasons:
- their safe side depends on the query (an excluded area should grow, a cheap one should shrink);
- they are rarely dense.

**Convex rings need a second move.** Removing vertices from one side can't simplify a convex
obstacle, such as a 24-gon cylinder Part: every vertex is a corner, and dropping one shrinks it.
- The complementary one-sided move is **collapse by extension**: replace edge (b, c) by the point
  p where the lines through its two neighbouring edges meet, when p lies on the free side within
  ε of (b, c). The obstacle gains triangle b-p-c.
- p is not a grid point. Round it to the neighbouring grid point that lies outside both lines,
  checked with exact `Orient2D`. That keeps G1 exact on the grid.
- On `rocks`, vertex removal alone (R16) gives −18% triangles. Adding this move (R16c) gives
  −32%.

**Where it sits: P1, in `quantizeRing`.**
- It runs after quantization and validation, and before the height surface is built.
- Only walkable rings whose surface is **planar** are simplified. A removed vertex's height lies
  on the plane, so the surface doesn't change. Non-planar rings are left alone, because there a
  vertex carries a crease.

**Snap rounding and the exact predicates.**
- Simplification runs before snap rounding, which then treats the simplified rings like any
  others. G8 is untouched.
- Snap rounding still moves every wall by up to half a pixel diagonal (√2/512 ≈ 0.0028 stud), in
  either direction, as it does today. So an ε below 1/256 means nothing.

**Adjacent and touching obstacles.**
- **Overlaps need no union.** The CDT's winding classification already computes the union.
  - Pre-unioning every scene's obstacles (U) changed the kept triangle count by 0.0-1.7% on the
    box maps.
  - It only shrank the discarded part of the CDT (props CDT triangles: 5704 → 5068).
- **Merging across two touching boxes' nearly collinear edges** needs the union boundary. That
  only exists per tile, after the first classification (P3). This is the user's exact example:
  two crates side by side, one rotated a degree.
  - On the scene built for it (`pieces`: 150 near-touching crate pairs, rotated up to ±1°),
    union then simplify at 1/16 removed only 4.7% more triangles than the union alone
    (2930 → 2793).
  - On the box maps it removed 0.7-1.9%.
  - That doesn't pay for a P3 simplifier. P1 plus the exact dissolve (R2) captures almost all of
    it.
- **Slivers between nearly touching boxes** are a different problem. A sliver of free space a few
  pixels wide is not a chord-deviation problem:
  - the chord across a gap's mouth deviates by the gap's depth, not its width;
  - closing gaps is C3 below. Its prototype added triangles, and its exact form found nothing to
    remove.

**Chains that cross tile lines, seams and area boundaries.**
- **Tile lines:** P1 runs before the tile grid exists. The tile clip then cuts the simplified
  ring as usual.
- **Seams:** vertices within ε of a floor's seam are pinned. Without that, shrinking a walkable
  ring can pull its edge off the seam, and Build then errors "does not lie on floor". Each seam's
  own ends are exact grid points and never move.
- **Area boundaries:** areas are untouched. Snap rounding re-meets them with the simplified
  walls.
- **Links:** a link end within ε of a shrunk wall still snaps, because `LINK_EXTENTS` is 0.5
  studs.

**`Update` and Serialize.**
- `AddObstacle` runs `QuantizeRing` with the same rule, so a dynamic obstacle is simplified
  exactly like a baked-in one.
- Checked with a scratch oracle:
  - 6 dense, notched dynamic obstacles on a dense floor, with 9-42 vertices simplified away each;
  - `Update` equals a fresh Build (triangles and widths), and removal restores the mesh, 6 of 6;
  - all 24 Obstacles specs also pass with the prototype at 1/16.
- The bake stores the simplified rings. It also needs ε, so that `AddObstacle` after
  `Deserialize` uses it: a v3 field.

**Measured (P1, per ring):**
- R16 = ε 1/16 by vertex removal;
- R16c = ε 1/16 with the collapse move;
- R4c = ε 1/4 with the collapse move;
- medians of 3 interleaved rounds.

| scene | variant | triangles | wall edges | Build ms (range) | FindPath 200× r0 | path mean / worst pair | kept area |
|---|---|---|---|---|---|---|---|
| rocks | base | 8380 | 7924 | 27,314 (27,091-29,379) | 131.5 | - | - |
| rocks | R16 | 6895 (−18%) | 6439 | 18,691 (18,682-19,440) | 109.6 | +0.02% / +2.8% | −0.02% |
| rocks | **R16c** | **5701 (−32%)** | 5245 | **10,894 (10,654-11,816)** | **93.0** | +0.05% / +2.8% | −0.03% |
| rocks | R4c | 2866 (−66%) | 2628 | 3,720 (3,286-4,015) | 69.5 | +0.47% / +25% | −0.27% |
| pieces | base | 9909 | 3085 | 6,163 (6,015-6,568) | 184.8 | - | - |
| pieces | R16c | 9676 (−2.4%) | 2852 | 5,040 (4,996-5,214) | 180.1 | −0.07% / +3.1% | −0.003% |
| pieces | R4c | 9275 (−6.4%) | 2453 | 4,019 (3,874-4,070) | 164.2 | −0.02% / +3.3% | −0.06% |
| props, bench, terrain, walls, demo | R16, R4 | unchanged (box rings) | | within noise | | 1.0000 | |

**The +25% worst pair at ε 1/4 is not a closed gap. It is a search artifact:**
- On the base mesh the short route stays open up to radius 0.5.
- On the simplified mesh, the route through a forced waypoint on the original path is 269 studs,
  but `FindPath` returns 326.
- The corridor choice changed, not the geometry. See R3.

**Negative controls:**
- the same code at ε 0 reproduces the base mesh (the same triangles and area);
- the box maps lose 0 vertices;
- the prototype's `Build.Ring.Removed` counter is 0 on every box scene.

**Specs the prototype broke at 1/16.** In the `simplify-proto` worktree the full navmesh suite
gave 198 passed and 2 failed. Both failures are expected contract changes:
1. **"a tilted planar ring gets no crease constraints: same triangles as flat."** The prototype
   simplified only flat rings, and dropped an exactly collinear point from the flat ring but not
   the tilted one. The real rule ("planar") treats both alike.
2. **"random sloped floors with random tile sizes."** `MeshChecks.Region`/`Walls` compare the kept
   region to walkable minus obstacles within 1/128 stud. They must become one-sided:
   - kept ⊆ region, within the snap wobble;
   - region eroded by ε ⊆ kept.

   That one-sided check is the new spec.

## Candidates

For each candidate:
- **what** it does;
- the **guarantee** it keeps;
- the **tolerance** and its default;
- the **risk**;
- the **spec** that proves it;
- **where** it sits;
- its **`Update` and Serialize** behaviour;
- the **measured** gain.

### C1 (recommended as R2): dissolve same-class constraint edges

**What.** In `triangulateTile`, after the first CDT and the keep/area classification:
1. Look for constraint edges whose two sides are both kept, with the same area and the same height
   plane. Open edges (seams, creases) and tile edges don't count.
2. If there are any, triangulate again, fed only:
   - the class boundaries as balanced loops: the kept boundary as group 1, and each area's
     boundary as its group;
   - the open edges;
   - the tile rectangle;
   - every border vertex.

This removes walkable-over-walkable edges, same-id area overlaps, and the hot pixels those edges
created.

**Guarantee: G5, exact.**
- The first CDT's edges don't cross, so the second adds no vertex (G8).
- Border vertices are kept (G6).
- Measured: the kept area per area id matched the base to the last printed digit on pieces and
  bench.

**Height-plane rule (required).**
- The prototype first classified by kept and area alone. The spec "errors on overlapping rings at
  different heights" then failed: Build still erred, but with a different message.
- Two walkable rings at different heights must never merge. Putting the ring's plane in the class
  (planar rings only) fixes it, and also covers creases between coplanar triangles.

**Tolerance:** none.

**Cost.**
- The second CDT runs only in tiles that have a dissolvable edge: pieces 96 tiles, bench 13,
  props, terrain, walls, rocks and demo 0.
- Box maps therefore pay nothing. Triangulation is 0.6-14% of Build, which bounds the worst case.

**Where: P3,** the one function Build and `Update` share, so G7 is automatic. Confirmed three ways:
- A scratch oracle over overlapping walkable pieces and same-id areas, with 4 obstacle placements
  across dissolved edges and tile lines: `Update` equals a fresh Build, and removal restores the
  mesh.
- The full spec suite with dissolve on passed 199 of 200. The one failure is the height-plane case
  above.

**Serialize:** the baseline is unchanged, and the dissolved triangles are baked. There is no
parameter, so no format bump.

**Risk:** low. The height-plane rule is the one trap.

**Spec:**
- (a) Random floors of overlapping walkable pieces and same-id areas: the per-area kept area, the
  wall set and the widths are equal with dissolve on and off.
- (b) The `Update` oracle over those floors.
- (c) Negative control: overlapping rings at different heights still error, with the original
  message.

**Measured:**

| scene | variant | triangles | FindPath 200× | Build | path length |
|---|---|---|---|---|---|
| pieces | base | 9909 | 166-185 ms | 4.9-5.5 s | - |
| pieces | **dissolve per tile (real prototype)** | **5377 (−46%)** | **76-94 ms** | **4.0-4.1 s** | −1.8% (sum over 200) |
| pieces | union upper bound (U, input level) | 2930 (−70%) | 49 ms (5-round median) | 2.5 s vs 5.0 s | −0.8% mean |
| bench | dissolve per tile | 4571 (−0.7%) | same | same | +0.001% |
| props, terrain, walls, rocks, demo | dissolve per tile | no dissolvable tile | - | - | identical |

The per-tile prototype keeps more triangles than the union because the pieces' overlap strips run
along 16-stud Part seams. Those lie on tile lines, whose border vertices stay pinned.

**Content that needs it:** floors authored in pieces (story 4, "author a floor in pieces"), which
is what a Part adapter emits.

### C2 (recommended as R1): one-sided ring simplification (the user's idea)

See the section above.

**Tolerance:** `SimplifyTolerance` in studs. Recommended default 1/16, with 0 meaning off (D1).

**Where:** P1.

**Risk:** low to medium. Seam pinning and the one-sided region specs are the work.

**Spec:**
- the one-sided region check;
- widths at ε ≤ widths at 0 (G3);
- a `FindPath` success at radius r with ε > 0 implies a success at ε 0 (G4);
- the `Update` oracle with dense obstacles;
- a seam on a dense walkable ring still pairs;
- a Serialize round trip, then `AddObstacle`, equals the live mesh.

**The P3 variant (simplify union boundaries per tile) is not recommended.** It gains only 0.7-4.7%
over C1 plus P1, for a second triangulation and a chord-against-hot-pixel validity check.

### C3 (skip): close gaps narrower than the smallest agent

**Exact form:** delete only free space that no disc of radius g/2 reaches.
- This is exact for every agent of radius ≥ g/2: such an agent's disc is a union of g/2 discs.
- As a component rule (U+D50: drop kept components with no 0.25-stud disc), it found **0-3
  triangles** on every scene.

**Approximate form:** a mitre opening, clipped back to the region (U+O25). It **added**
triangles:

| scene | triangles | Build (5-round median) |
|---|---|---|
| props | 3152 → 4183 (+33%) | 1.19 → 2.35 s |
| pieces | +32% vs U | 2.5 → 5.4 s |
| rocks | +3% vs U | about the same |

The offset curves are new geometry.

**Upper bound on the target.** Triangles whose every width is below 0.5 stud: props 14%, bench
4.5%, walls 10%, terrain 1%, pieces 14%, rocks 21%.

Dropping those isn't exact, and it isn't free:
- A bigger agent's disc can overhang the sliver's mouth. A new wall there cuts that agent's
  clearance by up to r − √(r² − w²/4).
- It needs a new contract (`MinAgentRadius`, refusing smaller radii).
- It removes paths for small agents.

**Verdict:** skip. There is nothing exact to take, and the approximate form costs more than it
saves.

### C4 (skip): drop small obstacles, obstacles inside obstacles, and small holes

- **Dropping obstacles below a size threshold invents walkable space** (G4), so it's rejected
  outright. A 0.3-stud prop is still a prop.
- **Obstacles inside other obstacles:** the CDT already discards their triangles. Pre-unioning
  saved nothing outside the noise on the kept mesh or on Build (props U 1.27 s vs base 1.19 s,
  ranges 0.8-1.7 s).
- **Tiny enclosed walkable pockets:** filling them is conservative. Their exact criterion is C3's
  component rule, which found almost nothing.

**Verdict:** skip.

### C5 (this is C2): Douglas-Peucker on dense rings

Plain Douglas-Peucker is two-sided: its chord can pass on either side of the removed vertices. That
breaks G1, and with it G3 and G4. The one-sided greedy form above is the safe version.

### C6 (folded into C1): merge coplanar and equal-area triangles across non-essential edges

**Coplanar and equal-area edges** are C1, plane rule included.

**Creases** come only from non-planar walkable rings. Planar rings get none (SR6).
- A crease between coplanar surface triangles can be skipped exactly.
- No bench content or demo ring is non-planar, so this is unmeasurable today.
- It comes free with C1's plane rule.

**The equal-cost area boundary** (the dogfood report's +8%) is not geometry. Evidence, from 200
fixed pairs at radius 0 with all costs 1:

| scene | change | mean | range | >1% longer | >1% shorter |
|---|---|---|---|---|---|
| demo | mud area removed (A0) | +0.01% | 0.80x-1.19x | 8 | 14 |
| bench | 64 area patches removed (A0) | +0.23% | 0.93x-1.13x | 39 | 30 |

- Removing the area constraints makes as many paths longer as shorter.
- The dogfood pair is one tail of that spread. The same spread appears after any mesh change:
  - one tile per floor: 0.81x-1.29x;
  - the rocks worst pair: +25%.
- The cause is that A* over edge-midpoint nodes picks a corridor, and the funnel is only optimal
  inside it.
- An area with its own id must keep its boundary anyway, because a query may price it
  differently.

This goes to ticket 25 as R3.

### C7 (skip): remove redundant Steiner and interior vertices after Refine

- NavMesh never calls `Refine`, and the CDT is forbidden to add vertices.
- Hot-pixel vertices are the corners where obstacles overlap (see "What the pipeline allows").
- Vertices that no constraint uses come only from dissolvable edges, and C1 removes them.

There is nothing left to do.

### C8 (skip): a coarser grid for far-from-agent detail

- The mesh is agent-independent and built once, so at Build there is no "far from the agent".
- The 1/256 grid is exactness machinery (SR2), not level of detail. Coarsening it enlarges the
  snap wobble of every wall, everywhere.
- Controlled detail reduction for dense content is exactly what C2's ε does, with a bounded
  error.

### C9 (skip as its own pass): edge collapse with clearance preservation

Slivers are common. Triangles under 5°:
- props 9%, bench 9%, terrain 9%;
- walls 33%, pieces 42%, rocks 54%.

C1 and C2 already remove the slivers that have a cause:
- pieces: 4120 → 1360 under the union;
- rocks: 4523 → 2327 at R16c.

The rest are the best triangulation their constraints allow:
- Collapsing an interior edge moves a vertex, so it needs a re-snap and a new G8 check.
- Collapsing a wall edge is C2.

### C10 (defer): convex polygons instead of triangles for search

**Measured potential:** a greedy Hertel-Mehlhorn merge within each tile and area leaves 35-59% of
the triangles as polygons. That is about half the search nodes on every scene.

**Against:**
- `FindPath` already takes 0.1-0.8 ms per query.
- Clearance is stored per triangle corner, and a polygon would need a width per pair of its
  edges. plan.md already flags this conflict.
- Search, Funnel, Snap, Serialize and widths would all change.

Revisit only if search becomes the bottleneck.

### C11 (skip): drop tile-line constraints where tiles have identical baselines

**Measured cost of tile lines** (variant T1, one tile per floor, against the default tiling):
- triangles: props −12%, bench −13%, terrain −9%, walls −21%, pieces −18%, rocks −7%;
- Build: 15-50% faster on five scenes, but **84% slower on rocks** (20.6 → 37.8 s), where one
  1024-stud CDT and one clearance pass get expensive;
- **`FindPath`: 2.1-5.6x slower on every scene**, because tiles are the snap index;
- paths: mean 0.0% to −1.0%, range 0.81x-1.29x (the same corridor noise as C6).

**Against:**
- Merging tiles also widens `Update`, which ticket 22 is making local.
- Tiles with identical baselines (empty and fully walkable) already cost 2 triangles each.

### C12 (fold into C1's specs): drop areas that can't matter

An area whose effective region is empty (later areas win over it, or it sits wholly under
obstacles or off the floor) can be dropped exactly. None of the 64 bench areas qualified. C1
removes such edges anyway.

### C13 (needs a ruling, D3): weld cracks between walkable pieces

Parts placed edge to edge leave cracks of hundredths of a stud, and every crack is a wall.
Filling a crack adds walkable space, which breaks G4, so it can't be automatic in the core. It
belongs either:
- in the Part adapter (ticket 26), as a weld tolerance;
- or behind an opt-in `FloorDesc.WeldTolerance`.

## Recommendation, ranked

| Rank | What | Effort | Measured gain | Risk |
|---|---|---|---|---|
| 1 | **C2 at P1:** one-sided ring simplification. ε in studs, vertex removal plus the collapse move, seams pinned, planar walkable rings only, areas untouched. | 2-3 days with specs, plus the bake field | rocks: −32% triangles, Build −60%, FindPath −29%, paths +0.05%. pieces: −2.4% triangles, Build −18%. Box maps: 0. | low-medium |
| 2 | **C1 at P3:** dissolve same-class edges, by kept, area and plane. | 2-3 days with specs | pieces: −46% triangles, FindPath about −50%, Build about −20%. bench: −0.7%. Others: 0, at no cost. | low |
| 3 | **R3:** corridor quality in ticket 25 (see below) | inside ticket 25 | the ±20% single-pair spread, which no geometry pass touches | low |
| - | Skip: C3, C4, C7, C8, C9, C11 | - | zero or negative | - |
| - | Defer: C10, and C2 at P3 | - | about 2x fewer search nodes; +0.7-4.7% | high / medium |

**For R3, ticket 25 has two options:**
- a shortcut pass over the funnelled path that drops any waypoint whose neighbours see each other
  (`Raycast` under the same filter and radius);
- a second funnel over the corridor, with the node positions re-optimised.

Either works for tile lines and area edges alike, and keeps both.

**Order:**
- **C2 first.** It is independent of everything else, and it lands with terrain or cylinder
  content.
- **C1 before the Part adapter's floors.**
- **Goldens.** Both change Build output where they apply, so review the changed goldens as PNGs.
  The fixtures are box rings, so few should move.
- **Serialize.** Only C2 needs a format change (ε in the bake). Fold it into the queued
  Serialize bump if that hasn't shipped.

## Decisions for the user

**D1. The default ε for C2.**

| Option | For | Against |
|---|---|---|
| (a) **1/16 stud** (recommended) | rocks −32% triangles and Build −60%; paths +0.05%; widths lose at most 0.125 stud | changes every dense mesh by default; goldens move |
| (b) 0 (off), opt in | no surprise | the win goes unclaimed unless the adapter or the user sets it |
| (c) 1/4 stud | rocks −66% triangles and Build −86% | paths +0.5%; widths lose up to 0.5 stud, a quarter of a typical R15 agent's clearance; gaps under 0.5 stud close |

**D2. The API shape.**

| Option | For | Against |
|---|---|---|
| (a) `NavMeshDesc.SimplifyTolerance: number?` (recommended) | one knob, stored once in the bake | the same everywhere |
| (b) `FloorDesc.SimplifyTolerance: number?` | terrain floors can be coarse and interiors exact | more surface, and `AddObstacle` must read its floor's value |

**D3. Welding cracks between walkable pieces (C13).**
- **(a) In the Part adapter only** (recommended). The core keeps G4 absolute.
- **(b) An opt-in `FloorDesc.WeldTolerance` in the core.** It would be the first knob that may add
  walkable space, so it must be off by default.

**D4. When C1 lands.**
- **(a) Before the Part adapter** (recommended). The adapter's floors are about 2x smaller from day
  one.
- **(b) When the adapter shows the need.** C1 does nothing on today's maps.

## Medians: every input-level variant

5 interleaved rounds on a shared machine. Build ranges run up to 2x, so read only large
differences.
- **Triangle counts are deterministic.**
- **Build:** median, then (range) in ms.
- **FP:** the sum over 200 `FindPath` calls at radius 0, best of 3, median over rounds.
- **Path mean:** the mean ratio against base over pairs that succeed in both.

**The variants:**
- **T1:** one tile per floor.
- **U:** obstacles unioned and walkable rings unioned (the kept region re-expressed as walkable
  rings and holes), with areas cleaned.
- **U+S64, U+S16, U+S4:** U, then one-sided simplification at ε 1/64, 1/16 and 1/4 stud.
- **U+O25:** U, then a mitre opening at g 0.25.
- **U+D50:** U, then dropping components with no 0.25-stud disc.
- **R16, R4:** per-ring vertex removal at ε 1/16 and 1/4.

**Clearance share of Build:** walls 79%, bench 87%, pieces 85%, terrain 90%, props 94%, rocks 99%.

**Bench maps, triangle counts:**

| variant | props | bench | terrain | walls |
|---|---|---|---|---|
| base | 3152 | 4605 | 1297 | 692 |
| T1 | 2786 | 4022 | 1183 | 550 |
| U | 3150 | 4597 | 1275 | 692 |
| U+S64 | 3142 | 4588 | 1275 | 682 |
| U+S16 | 3104 | 4574 | 1275 | 679 |
| U+S4 | 3150¹ | 4485 | 1272 | 667 |
| U+O25 | 4183 | 4642 | 1281 | 670 |
| U+D50 | 3149 | 4594 | 1275 | 666 |
| R16 / R4 | 3152 | 4605 | 1297 | 692 |

**Bench maps, Build in ms:**

| variant | props | bench | terrain | walls |
|---|---|---|---|---|
| base | 1187 (837-1669) | 1036 (749-1406) | 443 (272-527) | 287 (166-437) |
| T1 | 916 | 808 | 221 | 211 |
| U | 1266 | 1105 | 454 | 290 |
| U+S64 | 1300 | 1045 | 418 | 243 |
| U+S16 | 1287 | 1183 | 425 | 273 |
| U+S4 | 1371 | 1084 | 419 | 292 |
| U+O25 | 2350 | 1056 | 429 | 250 |
| U+D50 | 908 | 1082 | 411 | 230 |
| R16 / R4 | 1352 / 1341 | 1077 / 1094 | 472 / 332 | 271 / 269 |

**Bench maps, FindPath (sum of 200, ms) and path mean:**

| variant | props FP | bench FP | terrain FP | walls FP | path mean |
|---|---|---|---|---|---|
| base | 49 | 70 | 26 | 22 | - |
| T1 | 189 | 264 | 55 | 47 | 0.990-0.999 |
| U | 52 | 79 | 31 | 22 | 1.000 |
| U+S64 | 56 | 75 | 30 | 23 | 1.000 |
| U+S16 | 53 | 81 | 28 | 23 | 1.000 |
| U+S4 | 58 | 78 | 26 | 25 | 1.000 |
| U+O25 | 71 | 75 | 28 | 20 | 1.0006 (props) |
| U+D50 | 35 | 82 | 30 | 20 | 1.000 |
| R16 / R4 | 59 | 78 | 28 | 21 | 1.000 |

¹ Props U+S4 fell back to the unsimplified region, because the prototype rejects the whole kept
region when any ring goes invalid. The real per-ring rule has no such fallback.

**Synthetic scenes and demo:**

| scene | variant | triangles | Build ms (range) | FP | path mean |
|---|---|---|---|---|---|
| pieces | base | 9909 | 5042 (3127-5894) | 157 | - |
| pieces | T1 | 8089 | 4271 | 566 | 0.9998 |
| pieces | U | 2930 | 2480 (1647-3242) | 49 | 0.9919 |
| pieces | U+S16 | 2793 | 2143 | 44 | 0.9916 |
| pieces | U+O25 | 3862 | 5445 | 60 | 0.9890 |
| rocks | base | 8380 | 20558 (14590-27244) | 98 | - |
| rocks | T1 | 7822 | 37833 | 553 | 1.0000 |
| rocks | U | 8378 | 22987 | 107 | 1.0000 |
| rocks | U+S16 | 6878 | 10948 | 55 | 1.0002 |
| rocks | U+S4 | 5711 | 10803 | 63 | 1.0001 |
| rocks | R16 | 6895 | 10378 | 85 | 1.0002 |
| rocks | R4 | 5761 | 11279 | 85 | 1.0001 |
| demo | all variants | 48 | 4 | 5-7 | 1.0000 |

## Reproducing

All scratch lives in `.bench/simplify/` (gitignored), plus a detached worktree at
`.claude/worktrees/simplify-proto` for the two code prototypes.

**`lune run .bench/simplify/export.luau`** dumps the four `tools/navmesh/bench/Scenes` maps and the
dogfood demo level (from `git show navmesh-dogfood:examples/navmesh-demo/Level.luau`) to JSON.

**`.bench/simplify/venv/Scripts/python .bench/simplify/variants.py`** needs shapely, which lives in
the scratch venv. It generates two synthetic scenes:
- **`rocks`:** a 720-point coast, 90 noisy rocks of 48-160 points, and 60 cylinder 24-gons, on 512
  studs.
- **`pieces`:** a 256-stud floor of 16x16 overlapping Part pieces, each rotated up to ±0.15°, with
  4% missing. It also has 150 near-touching crate pairs rotated up to ±1°, and 40 cylinders.

It also generates the input-level variants. Beyond those in the medians section:
- **A0:** areas removed.
- **R16c, R4c:** per-ring vertex removal plus the collapse move, at ε 1/16 and 1/4. These are
  generated by `per_ring(desc, eps, True)`.

**`lune run .bench/simplify/measure.luau <rounds> <scenes...>`** builds each variant with the
unmodified library, in shuffled interleaved order. For each variant it records:
- **phase times,** by wrapping `CDT.Triangulate`, `Quantize.SnapRound` and `Clearance.Compute`;
- **round-1 mesh statistics:**
  - vertex classes;
  - slivers;
  - the Hertel-Mehlhorn polygon count;
  - triangles with every width below g;
- **`FindPath` over 200 fixed pairs,** at radius 0 and 1.

`SIMPLIFY_VARIANTS` and `SIMPLIFY_OUT` select the variants and the output file. The result files
are:
- `results.jsonl`: 5 rounds;
- `results_a.jsonl` (A0) and `results_d.jsonl` (R16, R16c, R4c): 3 rounds each.

**`python .bench/simplify/report.py [file]`** prints the tables. `worst.luau` is the rocks
worst-pair diagnosis.

**`simplify-proto`** holds the two code prototypes:
- `Build.Dissolve.Enabled` (C1) and `Build.Ring.Eps` (C2) are the prototype switches;
- `dissolve_probe.luau`, `ring_probe.luau`, `oracle_probe.luau` (C1) and `oracle_probe2.luau` (C2)
  are the probes;
- `lune run coverage.luau package=navmesh` produced the spec runs quoted above.

It is scratch: delete the worktree when you are done with it.
