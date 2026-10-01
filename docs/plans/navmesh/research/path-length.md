# Path length against the exact shortest path (ticket 25, "area-edge bend")

Branch `proto/g-areabend` (2026-10-01). This is a measurement and prototype study. Nothing in it
is merged. The question is how far `FindPath` is from the true shortest path at radius 0 with
equal area costs, how much of that gap sits at area edges, and what each candidate fix buys.

## Summary
- **The excess is general, not an area-edge effect.** Over 32k random pairs on 16 small scenes:
  - mean +1.2%, p95 +7.4%, p99 +18%, max +133% (a 2.33x path on a maze scene);
  - 19.5% of paths are more than 1% too long.
  - Removing the areas changes the mean by under 0.1 point on every scene but repro 4's (which
    is a convex room, so its whole excess is area-made). Paths whose shortest route crosses an
    area edge are worse by about 0.3-0.5 points of mean excess and 5-15 points of the >1% share.
- **Repro 4's "+8%" understates it.** In repro 4's own room, one pair comes out **2.01x** the
  straight line: start in the patch near its top edge, goal just above. The cause is the
  start's two neighbours. The node across the short edge sits at a midpoint near the goal, and
  the right neighbour's sits far off; f picks the wrong one, and the goal is reached through it
  before the right one is expanded.
- **Where the node sits on the entry edge is the whole story.** Placing it at the point of the
  edge that minimises |parent node - x| + |x - goal| (Heron's reflection; "heron" below), instead
  of the midpoint:
  - mean +0.09%, p95 +0.36%, max 1.23x; 2.7% of paths are >1% long;
  - FindPath gets **2x faster at r = 0** on the props and bench maps, because the open list pops
    3-4x fewer triangles;
  - no reachability change (0 status flips).
  - Its cost: goal-ward nodes overprice a route that heads away from the goal (round an
    expensive area, back to a cheap link). Gated to "every multiplier is 1" it changes nothing
    for weighted queries. Two model-pinning specs then fail and would need rewriting.
- **The post-pass shortcut alone helps little.**
  - mean +0.94%, p95 +6.0%, max 2.33x;
  - 3.5-3.9x FindPath time in this unoptimised form;
  - all 271 specs pass.
  - It fixes repro 4 completely, but not a corridor that goes round the wrong side of an
    obstacle, which is most of the excess.
- **The Theta*-like any-angle search loses to Heron on every count.**
  - mean +0.72%, p95 +4.2%, max 2.33x;
  - about 6.7x the search time of its own baseline copy;
  - 5 specs fail.

## The reference (`tools/navmesh/bench/PathOracle.luau`)
- **What it is:** a visibility graph over the reflex wall vertices, plus pinch vertices where 3+
  wall edges meet, with start and goal added, searched with Dijkstra.
- **Scope:** flat single-floor meshes. Areas are not walls, so with every cost equal the
  shortest path ignores them.
- **Why exact edge tests, not `Queries.Walk`/`Raycast`:** the oracle must not share code with
  what it judges, and the walk's float exit tests are exactly what a graze would stress.
  - Visibility uses `CDT.Orient2D` (exact for all f64 input) against `Storage.IsWallEdge`
    edges.
  - Vertex coordinates are on the 1/256 grid and stay exact through f32 storage, so the
    vertex-vertex tests are exact. Query endpoints are random floats, where a graze has
    probability zero.
- **Grazing.** The region is treated as closed:
  - a proper crossing of a wall edge blocks;
  - otherwise the segment is cut at every wall vertex lying on it, and each piece's midpoint
    must lie in a mesh triangle (exact test).
  - A piece that neither crosses a wall nor meets a wall vertex is wholly inside or wholly
    outside, so this lets a sightline that touches a corner, or runs along a wall, pass. It fails
    one that passes through a vertex into a wall.
- **Validation** (`lune run tools/navmesh/bench/path_length_oracle.luau validate`, all `ok`):
  - convex room (repro 4 without its area): 300 pairs, max ratio exactly 1.000000000000;
  - 20x20 room with a 4x4 box, all matched to 1e-9:
    - around the box: 2 sqrt(40) + 4;
    - along the box's wall (collinear run): 16;
    - grazing the corner (8, 8): sqrt(128);
    - the diagonal through the box is blocked;
  - reflex nodes (13) vs all 22 wall vertices on the Courtyard: identical lengths over 200 pairs.
- **Running checks on every measured pair:**
  - FindPath is never shorter than the oracle (by more than 1e-6);
  - the oracle's path, sampled every 0.01 stud in f64, stays in the mesh (first 50 pairs per
    scene).
- **Negative controls**, each caught:
  - `open` (a run along a wall blocks): the along-the-wall case becomes inf, and the ratio check
    fires on the Courtyard;
  - `nocross` (crossings ignored): goes through a thin wall (10.0 vs 16.55), and the sampling
    check fires;
  - `halfnodes` (drop every other reflex node): the oracle comes out longer than FindPath, and
    the ratio-floor check fires.
- **Gotcha:** `vector` arithmetic is f32. Lengths and sample points must be computed from
  `.X`/`.Z` in f64, or a run along a wall samples a micro-stud outside and the convex room reads
  1.0000001.

## Scenes
All are flat and single-floor, with the default tile size unless named.

| scene | what |
|---|---|
| repro4 | 40x40 room with repro 4's area-2 patch (0..30, 18..26); "no area" variant |
| Courtyard | fixture, with and without its area patch |
| ShallowObstacles | fixture |
| bench-like 64 | 64-stud room, 41 rotated 2-8 stud boxes + 4 area patches (the bench scene's densities); no-area and TileSize 8 variants |
| props-like 24 | 24-stud room, 72 rotated 0.3-2 stud props |
| walls-like 64 | 64-stud room, 10 thin axis walls (5-26 studs x 0.5) |
| soup 48 #1-#5 | 48-stud rooms of random rotated boxes (15-40 boxes of 1-10 studs), some with 6 area patches; #5 at TileSize 4 |

**Not used:**
- SplitLevel and TwistedQuad: they are not flat, so a plan visibility graph is not their 3D
  shortest path.
- The multi-floor fixtures.
- The full-size bench scenes: their O(V²) visibility graph is too slow in Lune. They appear in
  the timing and A/B runs instead.

## Measured distributions (r = 0, no AreaCosts, 2000 seeded pairs per scene)
Ratio = FindPath polyline length (3D, f64) / oracle length. Pairs are uniform in plan
(`FindRandomPoint` with `math.random` after `math.randomseed`). 11 pairs are unreachable and
skipped.

| scene | base mean / p50 / p95 / p99 / max / >1.01x | heron | shortcut | heron + shortcut | theta |
|---|---|---|---|---|---|
| repro4 | 1.0057 / 1 / 1.0394 / 1.1118 / 1.3107 / 9.4% | 1.0005 / 1 / 1 / 1.0156 / 1.0937 / 1.3% | 1 / 1 / 1 / 1 / 1 / 0% | 1 / 1 / 1 / 1 / 1 / 0% | 1.0042 / … / 1.3107 / 6.2% |
| repro4 no area | 1 everywhere | 1 | 1 | 1 | 1 |
| Courtyard | 1.0125 / 1 / 1.0996 / 1.2528 / 1.5319 / 11.6% | 1.0004 / 1 / 1 / 1.0120 / 1.1004 / 1.1% | 1.0093 / … / 1.5319 / 8.6% | 1.0003 / … / 1.1004 / 0.8% | 1.0067 / … / 1.5352 / 6.3% |
| Courtyard no area | 1.0120 / 1 / 1.0687 / 1.3006 / 1.7376 / 9.2% | 1.0002 / … / 1.0689 / 0.9% | 1.0105 / … / 1.7376 / 8.5% | 1.0002 / … / 1.0689 / 0.9% | 1.0096 / … / 1.7376 / 7.1% |
| ShallowObstacles | 1.0029 / 1 / 1 / 1.0796 / 1.4590 / 3.0% | 1.0009 / … / 1.1922 / 1.3% | 1.0029 / … / 1.4590 / 3.0% | 1.0009 / … / 1.1922 / 1.3% | 1.0006 / … / 1.1216 / 1.4% |
| bench-like 64 | 1.0153 / 1 / 1.0874 / 1.1650 / 1.5086 / 26.0% | 1.0016 / 1 / 1.0115 / 1.0305 / 1.0787 / 5.8% | 1.0146 / … / 1.5086 / 24.5% | 1.0015 / … / 1.0787 / 5.5% | 1.0083 / … / 1.5086 / 17.8% |
| bench-like 64 no area | 1.0149 / 1 / 1.0867 / 1.1707 / 1.3431 / 25.1% | 1.0015 / … / 1.0860 / 5.2% | 1.0143 / … / 1.3431 / 24.6% | 1.0014 / … / 1.0860 / 5.1% | 1.0101 / … / 1.3065 / 18.7% |
| bench-like 64 ts8 | 1.0116 / 1.0006 / 1.0510 / 1.1028 / 1.3840 / 30.1% | 1.0022 / … / 1.1235 / 6.8% | 1.0087 / … / 1.3840 / 21.8% | 1.0016 / … / 1.0791 / 5.2% | 1.0072 / … / 1.2659 / 19.2% |
| props-like 24 | 1.0221 / 1 / 1.1124 / 1.2214 / 1.3831 / 35.0% | 1.0008 / … / 1.0538 / 2.2% | 1.0189 / … / 1.3831 / 31.6% | 1.0007 / … / 1.0505 / 1.9% | 1.0112 / … / 1.8712 / 22.0% |
| walls-like 64 | 1.0158 / 1 / 1.1123 / 1.3004 / 2.3335 / 10.2% | 1.0006 / … / 1.2331 / 1.2% | 1.0090 / … / 2.3335 / 5.7% | 1.0003 / … / 1.0640 / 0.9% | 1.0112 / … / 2.3335 / 8.1% |
| soup 48 #1 | 1.0123 / 1 / 1.0645 / 1.1440 / 1.2985 / 25.5% | 1.0010 / … / 1.0674 / 3.7% | 1.0086 / … / 1.2985 / 16.8% | 1.0008 / … / 1.0589 / 2.9% | 1.0074 / … / 1.4816 / 14.5% |
| soup 48 #1 no area | 1.0138 / 1 / 1.0849 / 1.1656 / 1.4445 / 21.9% | 1.0008 / … / 1.0699 / 2.6% | 1.0121 / … / 1.4445 / 18.9% | 1.0007 / … / 1.0699 / 2.3% | 1.0088 / … / 1.4445 / 14.8% |
| soup 48 #2 | 1.0171 / 1 / 1.0916 / 1.1769 / 1.6900 / 29.2% | 1.0009 / … / 1.0455 / 3.1% | 1.0120 / … / 1.4541 / 21.0% | 1.0007 / … / 1.0455 / 2.5% | 1.0108 / … / 1.6900 / 18.9% |
| soup 48 #3 | 1.0127 / 1 / 1.0744 / 1.1590 / 1.4651 / 22.7% | 1.0004 / … / 1.0443 / 1.3% | 1.0102 / … / 1.3166 / 19.4% | 1.0004 / … / 1.0443 / 1.3% | 1.0084 / … / 1.7670 / 15.0% |
| soup 48 #4 | 1.0157 / 1 / 1.1107 / 1.2688 / 1.5648 / 17.0% | 1.0010 / … / 1.1798 / 2.7% | 1.0153 / … / 1.5648 / 16.6% | 1.0010 / … / 1.1798 / 2.5% | 1.0083 / … / 1.4830 / 12.0% |
| soup 48 #5 ts4 | 1.0129 / 1.0045 / 1.0548 / 1.0985 / 1.2123 / 36.1% | 1.0012 / … / 1.0421 / 3.5% | 1.0041 / … / 1.1661 / 11.5% | 1.0005 / … / 1.0405 / 1.5% | 1.0030 / … / 1.0891 / 9.4% |
| **all (31,989)** | **1.0123 / 1 / 1.0736 / 1.1820 / 2.3335 / 19.5%** | **1.0009 / 1 / 1.0036 / 1.0225 / 1.2331 / 2.7%** | **1.0094 / 1 / 1.0597 / 1.1618 / 2.3335 / 14.5%** | **1.0007 / 1 / 1.0012 / 1.0199 / 1.1922 / 2.1%** | **1.0072 / 1 / 1.0422 / 1.1429 / 2.3335 / 12.0%** |

("…" = the p50 / p95 / p99 columns, in the raw output of `measure <mode> 2000`.)

**Sample size matters for the tail.** At 400 pairs per scene the overall max was 1.89 (base);
at 2000 it is 2.33. The p95 is stable.

**Per pair, against base:**
- heron is longer on 2.8% of pairs (worst 1.233x base) and shorter on 26.0% (best 0.43x);
- shortcut is never longer (by construction) and shorter on 13.9%.

### Area edges vs in general (2000 pairs, same pairs with and without the areas)
| scene | base mean with / without areas | base >1.01x with / without | base, shortest path crosses an area edge: n, mean, >1.01x | base, does not cross: n, mean, >1.01x |
|---|---|---|---|---|
| repro4 | 1.0057 / 1.0000 | 9.4% / 0.0% | 1176, 1.0094, 15.4% | 824, 1.0005, 0.8% |
| Courtyard | 1.0125 / 1.0127 | 11.6% / 10.3% | 500, 1.0116, 12.8% | 1500, 1.0129, 11.1% |
| bench-like 64 | 1.0153 / 1.0163 | 26.0% / 25.4% | 445, 1.0177, 35.1% | 1555, 1.0146, 23.4% |
| bench-like 64 ts8 | 1.0116 / 1.0109 | 30.1% / 27.0% | 441, 1.0129, 37.6% | 1559, 1.0113, 28.0% |
| soup 48 #1 | 1.0123 / 1.0130 | 25.5% / 20.3% | 1509, 1.0133, 29.2% | 491, 1.0092, 14.3% |
| soup 48 #2 | 1.0171 / 1.0225 | 29.2% / 27.1% | 1208, 1.0191, 36.5% | 792, 1.0142, 18.2% |

- **Base:** areas add almost nothing to the mean (-0.5 to +0.6 points; only repro 4's convex
  room shows a clean +0.57). They add 0.6-5 points to the >1% share. Paths crossing an area
  edge are somewhat worse than paths that don't, but the no-area excess (1.1-2.2%) dominates.
  This agrees with R3.
- **With heron** (same table, `areas 2000 heronlib`): with / without areas is 1.0005 / 1.0000
  (repro4), 1.0004 / 1.0003, 1.0016 / 1.0014, 1.0022 / 1.0019, 1.0010 / 1.0008 and
  1.0009 / 1.0007. Crossing pairs stay a little worse, for example repro4 2.2% vs 0.0% >1%
  long.

## The fixes, prototyped (`tools/navmesh/bench/PathProtos.luau`, `lib/navmesh/src/Search.luau`)

### (a) Shortcut post-pass, no Search change (`shortcut`)
**How it works:**
- It greedily replaces a run of waypoints with a straight surface walk, from each kept point to
  the farthest later one, when the walk is unblocked and its weighted cost (plan length times
  each triangle's multiplier) is lower.
- The walked triangles become a new corridor, which `Funnel.StringPull` pulls again, radius
  offsets included.
- It repeats, up to 4 rounds, while the path gets cheaper.

**Radius > 0.** A point walk ignores radius, so the sound variant checks the new corridor
against Search's own rule:
- the corner widths, and the start's portal width;
- the ticket 27 `Clearance.CutOff` at the start and goal;
- `Clearance.Separated` when start and goal share a triangle.

It also rejects a corridor that revisits a triangle, which Search handles with its start-again
and goal-again nodes. So its guarantee equals FindPath's.
- The first version lacked the `Separated` guard and failed the ticket 27 spec "ends parted
  inside one triangle go round when they can", which works as a negative control. With the
  guard, all 271 specs pass.
- At r > 0 the funnel's offset polyline is not always point-walkable, and the pass then keeps
  the path as it is.

**Links and seams:** a path with a link is left alone, since a link breaks the string. A
shortcut walk that crosses a seam is rejected; that is a prototype limit.

**Numbers:**
- mean 1.0123 → 1.0094, p95 1.0736 → 1.0597, max unchanged (2.33);
- repro 4 fixed exactly (all 2000 pairs at 1.0000);
- FindPath 205 → 708 µs at r = 0 and 278 → 1004 µs at r = 1 on the 256-stud bench map
  (300 pairs, median of 5);
- 0.4% shorter mean at r = 0 and r = 1.
- The cost is O(waypoints²) walks plus the re-pull. Limiting it to skip-one (i → i + 2) would
  cut that, untested.

**Why it is weak:** most excess is a corridor round the wrong side of an obstacle. The chord
between two corners of such a path is usually blocked by the very obstacle it went round, and
the funnel's corners are local, so there is nothing to shortcut.

### (b) Node-model alternatives (architecture forks)
**`heron`** (`Search.HeronNodes`, in the library behind a flag that defaults to off):
- **What changes:** a triangle's node sits on its entry edge at the point minimising
  |parent node - x| + |x - goal|. If both are on one side of the edge's line, the goal is
  reflected across it.
  - The point is clamped `min(r, half the edge)` off a wall-vertex end, as the funnel offsets.
  - Its height is interpolated along the edge.
  - About 25 lines; only edge nodes change, not seam portals or links.
- **Lengths:** see the tables.
- **Time** (`findpath_heron_ab.luau`, 400 pairs, interleaved, median of 7):

| scene (triangles) | r | midpoint µs | heron µs | time ratio | pops midpoint / heron | total length heron / midpoint |
|---|---|---|---|---|---|---|
| props (3152) | 0 | 152.0 | 72.5 | 0.48 | 432 / 107 | 0.9702 |
| props (3152) | 1 | 116.2 | 123.4 | 1.06 | 114 / 114 | 1.0027 (5 Success pairs) |
| bench (4605) | 0 | 219.6 | 105.9 | 0.48 | 657 / 189 | 0.9773 |
| bench (4605) | 1 | 307.4 | 245.5 | 0.80 | 682 / 418 | 0.9845 |
| terrain (1297) | 0 | 81.6 | 61.8 | 0.76 | 192 / 87 | 0.9787 |
| terrain (1297) | 1 | 116.5 | 91.0 | 0.78 | 190 / 88 | 0.9796 |
| walls (692) | 0 | 52.5 | 55.0 | 1.05 | 128 / 109 | 0.9990 |
| walls (692) | 1 | 67.8 | 71.4 | 1.05 | 75 / 72 | 1.0014 |

  No pair changes status (Success / Partial). At r > 0 Search's width rules are untouched: the
  set of admissible corridors is the same and only the choice among them changes, so the SR4
  guarantee is unchanged.
- **The catch: goal-ward nodes overprice routes that head away from the goal.**
  - **Ungated** (`heronlib`), 5 specs fail:
    - "cheap link behind the start" picks the 19.8 straight walk over the 18.6 warp: a real
      regression, 6% costlier;
    - the cheap-detour loop still goes north, but its search cost is 27.6 vs 19.55;
    - the Courtyard SR7 spots show A* vs Dijkstra gaps up to 19.7%;
    - the node-chain cost spec fails.
  - **With expensive areas** (`weighted base herongated`, multiplier 2 or 5, 400 pairs per
    row): the mean weighted path cost is 0.98-1.03x base, but single pairs come out up to
    2.74x costlier. Base has the same kind of outliers the other way: best heron/base 0.29.
  - **`gated`** (only at heuristic scale 1): 2 specs fail. Cheap areas and links keep
    midpoints, but expensive areas still get heron.
  - **`uniform`** (only when every multiplier is 1 or excluded, and scale is 1): **2 specs
    fail.** It is identical to base for every query with a non-1 multiplier: the `weighted`
    run shows 0 pairs differing across 21 rows.
    - The 2 failures pin the midpoint model:
      - "a path's cost is the cost of its own node chain" recomputes the chain with midpoints;
      - "A* finds Dijkstra's costs" disables heron in its Dijkstra run by scale 0, and in any
        case heron's parent-dependent nodes make A* ≠ Dijkstra.
    - Both would be rewritten: the first with the Heron rule, the second as a bound or an
      oracle check.
- **A* = Dijkstra is not a property of today's model either** (`sr7 base`, 300 random pairs):
  - base A* and Dijkstra costs differ on 2-153 of 300 pairs per scene, by up to 30% (A*
    worse);
  - the SR7 spec passes only on its chosen spots.
  - With heron (no AreaCosts) the gaps are at most 2.1%.

**`goalproj`** (the edge's point nearest the goal, fixed per edge like the midpoint) is much
worse: mean 1.0558, p95 1.27. The parent term is essential.

**`nearest`** (the point nearest the parent's node) gives mean 1.0063 and p95 1.039, with 8
specs failing.

**`theta`** (Theta*-like, cf. Recast's `DT_FINDPATH_ANY_ANGLE`):
- **What changes:** relaxing m from u also tries u's parent. If a straight walk from the parent's
  node reaches m's node through t, with a cheaper weighted cost and the corridor passing the
  clearance rules, m takes u's parent. The corridor is rebuilt by walking those jumps again.
- **Numbers:** mean 1.0072, p95 1.042, max 2.33.
- **Time:** 1726 µs at r = 0 and 2633 µs at r = 1, against 256 / 317 for the identical search
  copy without it (6.7x / 8.3x).
- **Specs:** 5 fail (node-chain cost, A* = Dijkstra, and the funnel-tightness spec, whose
  corridor rebuild I did not debug).
- **Why it is weak here:** the start's children still sit at midpoints and are priced from
  there, so the f-order mistake behind repro 4's 2.01x pair happens before any line-of-sight
  check runs.
- Not worth pursuing over heron.

### Combination
`heron + shortcut` gives the best lengths: mean 1.0007, p95 1.0012, max 1.19.
- The shortcut adds about 4x the heron time (493 µs vs 104 at r = 0) for a further 0.2 points
  of mean.
- It is not worth it unless the pass is made much cheaper.

## Options

| option | length ratio p50 / p95 / max (r = 0, 32k pairs) | FindPath time (bench map) | specs | radius soundness |
|---|---|---|---|---|
| 1. Keep as is, document | 1 / 1.074 / 2.33; 19.5% of paths >1% long | 1x | 271 pass | unchanged |
| 2. Shortcut post-pass | 1 / 1.060 / 2.33; 14.5% | 3.5x (r = 0), 3.6x (r = 1), unoptimised | 271 pass | sound: the new corridor passes Search's width rules and cut-offs |
| 3. Heron nodes, gated to uniform costs | 1 / 1.0036 / 1.23; 2.7% | 0.48x (r = 0), 0.80x (r = 1) | 269; 2 model-pinning specs to rewrite | unchanged: the same width rules, only a different choice of corridor |
| 4. Heron (3) + shortcut (2) | 1 / 1.0012 / 1.19; 2.1% | 2.4x (r = 0), 3.2x (r = 1) | 269 | as 2 + 3 |

- **Recommendation: option 3.** It is the only option that moves the distribution: p95 7.4% →
  0.36%, and the >1% share 19.5% → 2.7%. It also halves FindPath time at r = 0, and it is about
  25 lines in Search.
  - Gating it to "every multiplier is 1" leaves every weighted query exactly as today, so it
    carries no routing regression; the ungated version mis-prices links and expensive detours.
  - The costs:
    - two node models, chosen by the filter;
    - Search's doc and SR7's wording change: A* = Dijkstra stops being an exact spec, which
      today's model also only meets on its chosen spots;
    - two specs need rewriting.
- **Not recommended:**
  - the post-pass as the fix: small gain at 3.5x time;
  - Theta*-style search: worse than heron at 7x;
  - goal-only or parent-only placement.

## What I could not measure
- **No oracle for r > 0, for AreaCosts other than 1, or for multi-floor, sloped and link
  scenes.**
  - At r > 0 there are only relative numbers: heron is 1.5-2% shorter on bench and terrain,
    about equal on walls and props.
  - Weighted queries are compared by real weighted cost against base only.
- **The shortcut's time** is that of a naive prototype (O(n²) walks in Lune, plus a re-pull),
  and the theta timing carries the copy's 1.25x overhead. The heron timings are in-library and
  fair.
- **Heron is not applied at seam portals** (they keep midpoints), and its effect across seams is
  not measured.
- **Timings ran beside another session's mutation run**, so absolute µs are noisy. Ratios come
  from interleaved passes.
- **The scenes are small** (24-64 studs). The 1-4 km maps are Track H's.

## Reproduce (from the worktree root)
```
lune run tools/navmesh/bench/path_length_oracle.luau validate
lune run tools/navmesh/bench/path_length_oracle.luau measure base 2000      # also: shortcut, heronlib, heronlib+shortcut, theta, goalproj, nearest
lune run tools/navmesh/bench/path_length_oracle.luau areas 2000 base       # and: areas 2000 heronlib
lune run tools/navmesh/bench/path_length_oracle.luau compare base heronlib 2000
lune run tools/navmesh/bench/path_length_oracle.luau compare base shortcut 2000
lune run tools/navmesh/bench/path_length_oracle.luau sr7 base              # and: sr7 heronlib
lune run tools/navmesh/bench/path_length_oracle.luau weighted base herongated 400   # and: base heronuniform
lune run tools/navmesh/bench/path_length_oracle.luau time base,copy,shortcut,heronlib,heronlib+shortcut,theta
lune run tools/navmesh/bench/findpath_heron_ab.luau
lune run tools/navmesh/bench/path_length_oracle.luau specs <mode>          # base/shortcut 271; heronlib/theta 266; herongated/heronuniform 269
```
