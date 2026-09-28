# NavMesh mutation triage, 2026-09-28

Input: the full gate `mutation-final-2026-09-28.json` (150/150 specs, 98.6% lines, 78.4%
mutation). Branch `navmesh-hardening`. Scores are the gate's (detected / run, where
detected = killed + timeout + error), per file.

## Summary

The "after" column is a full re-gate of the package at the end
(`lune run coverage.luau package=navmesh --mutate --mutate-jobs=16`). It found 190/190
specs, 98.8% lines, and 84.4% mutation.

| file | before | after | survived before | survived after | equivalent | not killed |
|---|---|---|---|---|---|---|
| Tiles | 63.3% | 75.5% | 109 | 84 | 84 | 0 |
| Search | 66.9% | 85.5% | 48 | 21 | 16 | 5 |
| Clearance | 72.6% | 80.1% | 106 | 77 | 64 | 13 |
| Queries | 73.0% | 81.4% | 62 | 43 | 33 | 10 |
| Serialize | 77.9% | 88.5% | 23 | 12 | 11 | 1 |
| NavMesh | 78.4% | 99.0% | 21 | 1 | 1 | 0 |
| Build | 79.2% | 83.6% (83.7%) | 170 | 134 (133) | 128 | 5 |
| Funnel | 81.2% | 85.9% | 16 | 12 | 10 | 2 |
| whole package | 78.4% | 84.4% | 639 | 469 | | |

- **Equivalent** means judged unable to change observable behaviour, for the reason given
  per group below.
- **Not killed** means not proven equivalent: a real but narrow case that no test constructs.
- **Tiles** gained mutants, because the tile-line fix added code (343 run, was 297). Every
  Tiles survivor left is equivalent, mostly conservative margins and a vertex-rotation
  normalization that never engages. That's why its score stays under 85%.
- **Clearance** is below 85% for the same reason: 64 of its 77 survivors are equivalent.
- **Tests added after the final gate:** the crease-seam test (kills Build `822:48`, shown in
  brackets) and the Snap miss assertion (kills Snap `140:28` and `148:10`). Both were proven
  by applying the mutants by hand.
- **Why those two Snap mutants appeared:** they survived the final gate only because the
  link-drop fix now treats a nil snapped point as a miss, whatever the triangle.

**Real bugs found and fixed (2), both in `Tiles.luau`:**

1. **Update failed with "internal error: a ring crosses a tile line between snapped vertices".**
   Repro: 32 x 24 floor, `TileSize = 8`. Add obstacle A (x 16..17.5, z 9..11, west side on the
   tile line x = 16) and Update; add B across the tile corner (16, 16) and Update; remove A and
   Update. The third Update threw (and rolled back), so A could never be removed.
   Cause: the local re-snap snap-rounded the dirty tiles' baselines and the obstacles, but not
   the tile lines (Build does include them). B also crosses the line x = 16 above the re-snapped
   tiles, beside clean tiles, and `ClipToRect` clips against whole lines, so it met that crossing
   between snapped vertices. Fix: `reSnap` adds the floor's tile lines over everything it snaps,
   as Build does (`tileSize` was already fetched and unused). Test: "a run of adds and removes
   equals a fresh Build of the obstacles left" (also shifted to z + 64 so the X and Z ranges
   differ). It failed before the fix, and passes after it.
2. **After an Update, a link end near an obstacle's edge stayed inside the obstacle.**
   Repro: LinkJump, crate x 8.7..10, z 4.6..5.3 over the From end (9, 5), Update.
   `FindPath((2, 0, 2), (22, 0, 8))` routed through (9, 5), inside the crate. Cause: Update
   re-snapped each end with the 0.5-stud link extents to find its triangle, but kept the old
   point: it found the neighbouring uncovered triangle, so the link stayed "on" with a point off
   its triangle. Fix: an end whose re-snap moved it in plan is under an obstacle, so it drops
   out (triangle 0), which is the documented rule ("an end under an obstacle drops out for
   now"). The stored point is kept, so removing the obstacle restores the link exactly (SR14).
   Test: "a link end under an obstacle drops out even near the obstacle's edge, and comes
   back". It failed before the fix, and passes after it.

**Finding, not fixed (needs a ruling):** SR4's start rule doesn't check the start triangle's own
interior. With one big tile, the walled room `0..20 x 0..10` with a wall `x 10..11, z -1..9`
triangulates into a sliver start triangle `(0,10) (10,9) (20,10)` that spans the 1-stud gap.
`FindPath((9.6, 0, 9.5), (15, 0, 5), { AgentRadius = 0.51 })` returns Success. Leaving that
triangle reads the portal width of its exit edge (1.64 wide), but the agent has to pass the
1-wide gap inside the triangle first. The goal triangle has the same blind spot. A fix needs a
clearance measure from a point to an edge inside one triangle. That's beyond a small fix, so the
new gap test uses `TileSize = 2` and documents the limitation.

**How the tests were proven:** every new test was run against the mutants it targets, each
applied by hand to a copy of the package (`coverage-engine apply-mutant`). Each one failed on
a mutant, and the unmutated code passed. The re-gates below confirm the kills.

## Most common kinds of equivalent survivor

1. **Conservative margins and performance bounds.** These include the one-pixel dirty-tile
   margin, the clearance-reach lower bound, pruning bounds, and the doubling search limit. A
   mutant that widens the bound only costs time. A mutant that narrows it by one pixel can't
   matter, because snapped coordinates are integers.
2. **Ties and boundaries that can't arise.** Examples: `<` against `<=` on distinct keys or on
   integer grid values, and orientation `< 0` against `<= 0` where zero-turn corners are
   filtered afterwards.
3. **Loop starts at 0.** The extra iteration reads index 0, which is nil, and does nothing
   (`table.insert(t, nil)` and nil keys are no-ops).
4. **Redundant data.** Open-edge bits in the bake are re-derived by `Connect` on load.
   `true`/`false` values in key sets are iterated by key. Injective cache keys stay injective.
5. **Precision-only.** Regula falsi termination, the Illinois bookkeeping, and sub-1e-4
   "stop short of the wall" offsets.

## Tiles

**Tests added (NavMesh.Obstacles.spec):**
- "an update equals a fresh Build wherever the obstacle sits against the tiles": the obstacle
  is placed against each side of a tile line, across a tile corner, inside an upper tile, and
  across the outer wall. Each case uses tile sizes 8 and 16 and is compared on triangles,
  widths and draw list.
- "a run of adds and removes equals a fresh Build of the obstacles left" (the bug 1 repro).
- "an obstacle beside a seam leaves the seams a fresh Build makes".
- "an update on a ramp, and one narrowing a corridor across a tile line, equal fresh Builds":
  ramp heights, and the clearance reach into a clean tile.
- "a link on a slope stays usable through an update elsewhere".
- "a link end under an obstacle drops out even near the obstacle's edge, and comes back" (bug 2).
- "a change on one floor leaves paths on the floor above it valid".
- "any applied change invalidates paths through the tiles at a link's ends": also checks that
  an Update with nothing pending changes nothing, with links present.
- "RemoveObstacle rejects anything but a recorded id" (0, 1.5, "1", out of range).
- "obstacle errors point at the caller's line" (error level 3).

**Equivalent survivors:**
- `117` (all `<=`→`<`, `1`→`0`) and `339` (`<=`→`<`, `1`→`0`, `and`→`or`): the one-pixel
  margin and the covered-tile test. Boxes and tile rects are integer grid values and hot
  pixels stay inside the box, so a zero margin is enough. `and`→`or` only re-snaps more tiles,
  and re-snapping an obstacle-free baseline is idempotent.
- `245` (the border-vertex filter, 13 mutants): every border point a tile needs is already an
  endpoint of its own fragments. The broader mutants add duplicates or corners, and the
  narrower ones drop points that are present anyway. No oracle placement found a difference.
- `244:33` (`2v-1`→`2v`, adds point (z, z)): on origin-aligned square tiles, (c, c) passes the
  border test only at a tile corner, which is always a vertex.
- `222:33` (the chain's start vertex → its end vertex): the closed chain is rotated by one.
- `498`, `499`, `524` (triangle-key rotation, 19 mutants), `505`: rebuilt triangles keep
  their vertex order (the triangulator is deterministic), so the rotation normalization never
  engages. `505` (no old keys) recomputes every rebuilt triangle, which is correct but slower.
- `415:43` (`first + count`→`first - count`): CopyOut links in-tile neighbours through the open
  edges anyway.
- `535`, `536` (reach box `±1` pixel, `/`→`*`), `541:19` (reach 0→1), `545` (`<=`→`<`,
  `/2`→`*2`): a conservative or one-pixel reach. More recomputes and stamp bumps change no
  width. A shrink of 2/256 stud has no triangle within it in any scene.
- `449:48`, `466:48`, `547:54` (`true`→`false` in key sets): the loops iterate keys.
- `54` (LINK_EXTENTS, 3), `456`/`459` (the new drop tolerance, 4): the stored link ends lie
  on the surface, so re-snapping finds their own column exactly. A sloped link (tested) keeps
  its height exactly.
- `318` (heights keyed wrong, 2): the heights are recomputed from the same surfaces, which
  gives the same values. The ramp oracle confirms it.
- `164:42` (minZ from the X values): it only lengthens the added tile lines.
- `174:29`, `177:15` (a line starts at the origin): longer lines, as in Build.
- `65:10`, `148:11`, `288:13`, `434:14`, `440:13`: loop starts at 0 (nil no-ops).
- `353:37` (`#covered >= 0`): re-snapping nothing returns nothing.

## Search

**Tests added (NavMesh.FindPath.spec, NavMesh.Floors.spec):**
- "a path's cost is the cost of its own node chain (seams, links and area costs)": an
  independent cost recomputation over the corridor, for 6 scenes and 700+ pairs.
- "a cheap link behind the start still wins: links lower the heuristic scale": also run with
  the scene shifted across the origin and with a 0.2 link multiplier.
- "every step of a path with a radius has the clearance the rule asks for (SR4)": the rule is
  derived from the corridor alone, for radii 0.2, 0.45 and 1.1.
- "a small agent fits a small gap up to half its width, and no wider" (a 0.5-stud gap).
- "A* finds Dijkstra's costs between many pairs".
- "a start right beside a gap leaves over the gap's own width".
- "a small agent crosses a narrow seam up to half its width, and no wider" (a 0.75-wide bridge
  floor).

**Equivalent survivors:**
- `97:16` (scale 0), `103:37` (a missing link multiplier reads 0), `104:14` (disabled links
  counted), `107:14` (a zero-length link): they only lower the heuristic scale (a
  Dijkstra-like search), or cover a zero-length link that can't shortcut anything.
- `101:11`, `297:10` (loop starts at 0), `145:30` (stamps count down: any fresh value works).
- `171` (2): the start's priority doesn't matter, because it is the only open node.
- `207:13`, `223:14`, `258:14` (`width > 0`→`>= 0`): at radius 0 every check passes.
- `221:30`, `269:30`, `284:9` (ties between equal costs or distances).
- `293:42` (`vias[1]`): Funnel never reads the first via.

**Not killed (not proven equivalent):**
- `107:16` (`length > 1`): only a sub-stud link cheaper than walking can make the unscaled
  heuristic overestimate.
- `170:34` (the start's entry 0→1): in every scene tried, the start triangle's corner widths
  and portal widths agree on the verdict.
- `271` (3, the priority of seam and link successors): A* still returns Dijkstra's costs on
  every pair tried, including a scaled heuristic.

## Clearance

**Tests added (NavMesh.Clearance.spec):**
- "widths match a brute-force flood of the wall discs": for every triangle, it floods a
  barycentric grid in order of distance to the floor's walls. Scenes: slanted obstacles, the
  same at 1/16 scale, two stacked floors with different walls, ThreeFloorStairs (seams and
  open edges), and the Courtyard. Tolerance is the grid spacing. This test alone killed 30
  survivors, including the cell-key floor collisions, `crosses()`'s `< 1` threshold (via the
  1/16 scene), the closest-pair midpoint endpoints, and the portal-owner bookkeeping.
- "corners are passed at the agent's radius": now for r = 1.5 and 0.5, both ways round, and
  checking that each corner lies on the walkable side, r from the walls. (It covers Funnel.)

**Equivalent survivors:**
- `77` (7 of 10, `crosses()` sign tests, the parallel branch, and `<`→`<=`): mesh edges never
  cross properly, and touching segments give the same distance and midpoint.
- `93`, `94:10`, `96` (`k±1` parity, 2), `99:8`, `116:22`, `126:8`, `146`, `150`, `230:32`,
  `237:17`, `239`, `243:19`, `271:11`: initial values that get overwritten, the same candidate
  set, and ties in convex minima and Dijkstra.
- `243:13` (`or`→`and`), `252` (4, prefilters), `262` (2, the gap lower bound): pruning only.
  A pruned link can't lower a label.
- `256` (3, cache keys): the pair keys stay injective.
- `292` (6, wall-grid keys): these stay injective within ±32768 cells. (The mutants that drop
  the floor were killed by the stacked floors.)
- `307:82`, `308:83` (buckets `*CELL`): walls land in the wrong cells, the search doubles its
  limit until the whole range is searched, and the answer is still exact.
- `333:11`, `343:25`, `364:18`, `368:12`, `380:30`, `384:29`, `384:48`, `389:21`, `394`
  (`<=`→`<`, 2), `411:98`, `65:97`: extra or unread work, such as corners between wall edges
  and wall portals that no query reads, zero-length segments, and duplicate walls.
- `157:10` (65 iterations), `162` (5, the loop's exit test), `165` (3, the sign of `ha`, which
  stays negative): only the iteration count changes, not the crossing it converges to.
- `209` (2): more candidate edges, all inside the region.

**Not killed (precision or unreachable in practice, not proven equivalent):**
- `114` (3, `len2` in `nearestParam`), `154:49`, `155:15`, `167`, `168`, `170`, `173`, `176`
  (7, Illinois bookkeeping): the regula falsi on a triangle edge. The brute-force flood, at
  grid resolution, sees no difference. The class docs promise only "a hair wide, never
  narrow".
- `394:43` (the exactness check reads the corner twice): it needs a portal wider than 8 whose
  triangle's corners are all narrower than 8. No scene has one.

## Queries

**Tests added (NavMesh.Queries.spec):**
- "crosses a slanted seam wherever the ray meets it, both ways": the Deck scene, where a sliver
  on the Deck splits one Ground edge's portal in two. The down-the-ramp Raycasts are also new.
- "slides along a slanted wall to where the move projects onto it": with a radius, it ends
  exactly r from the face.
- "a point on a wall is at 0, with the wall's inward unit normal".
- "evenly spread picks land in triangles in proportion to their areas": a stratified rng
  against independently computed areas, with and without an excluded area.
- "points in a circle fill it evenly, out to its edge".
- "argument errors point at the caller's line; small and zero radii are fine".

**Equivalent survivors:**
- `46:57`, `225:47` (a missing multiplier reads 0: not `math.huge`, the same verdict).
- `66:16`, `67:10`, `71:24`, `92:77` (Y is ignored), `124:23`, `175:10`, `196:11`, `244:10`,
  `241:15`, `264:14`: initial values, loop starts, and extra slides, tries or pushes.
- `85:9`, `89:26`, `140:9`, `147:10`, `189:22`, `198:26`, `232:57`, `249:23`, `260:67`,
  `194:12`: ties and boundaries (a ray through a vertex, a target exactly on an edge).
- `198:21` (`or`→`and`): `normal == nil` only when `d == radius`, so the same break happens.
- `236:71` (`*0.5`→`/0.5`): all areas scale alike, so the distribution is the same.
- `187:46`, `183:44` (the Y of a planar vector).
- `183:37`, `183:54`, `185` (4), `189:24`: sub-1e-4 offsets and the slide's 1e-6 cut-off in
  "stop just short of the wall". Every assertion is at 1e-3 or above, which is where the
  behaviour is specified.

**Not killed:**
- `31:12`, `35:34` (links with `ref == e` taken as seams): this needs a link whose id equals
  the open edge's index on the same triangle, with the hit projecting onto it. No scene has one.
- `37:51`, `38` (6, the portal-membership tolerance and test): with the in-range test off, the
  walk continues from the adjacent Deck triangle and still arrives.
- `232:55` (`dz^2`→`1` in the circle's candidate filter): it only drops triangles in a
  1-stud rim band, and statistics can't see that.

## Serialize

**Tests added (NavMesh.Serialize.spec):**
- "a loaded mesh answers every query like the original (walls, seams, radius)": FindPath with a
  radius, Raycast, MoveAlongSurface and FindDistanceToWall over pairs, then an Update on both,
  compared byte for byte.
- "link toggles and one-way links survive a round trip".
- "meshes of many sizes round-trip (the writer grows at any byte)".
- The load errors: a 2-byte buffer, a header-only buffer, and "every message is the module's
  own, with no source position".

**Equivalent survivors:**
- `44`, `45` (growth boundaries), `115:59` (the size is overwritten), `116:13` (the first
  buffer is 1024 bytes).
- `169` (2), `171:27`, `336` (2), `337:39`: the open-edge bits. `Connect` re-marks every seam
  edge open on load, so the bits are redundant.
- `209:33` (`+`→`-`): u8 two's complement keeps both flag bits.

**Not killed:** `61:13` (u16 without reserve): it needs a u16 to land exactly on a doubling
boundary, and in this format u16s are only string lengths.

## NavMesh

**Tests added:**
- Filter and argument errors point at the caller's line (FindPath, MoveAlongSurface,
  FindDistanceToWall, FindRandomPoint, SetLinkEnabled).
- `AgentRadius = math.huge` is rejected; zero and fractional SnapExtents, a 0.5 maxRadius,
  and circle radii of 0 and 0.5 are accepted.
- SetLinkEnabled rejects 0, 1.5 and "1".
- "toggling a link with a covered end bumps only its other end's tile".

**Equivalent:** `272:19` (`bumped[tile] = false`): a second bump changes the stamp value but not
validity.

## Funnel

**Tests added:** the funnel oracle ("the tight string through its corridor") now also runs on
the Courtyard at 1/16 scale. The radius-corner test (see Clearance) runs for r = 0.5 and in
both directions, and checks the walkable side.

**Equivalent survivors:**
- `35` (3, initial indexes): the first portal always sets them.
- `53:17`, `68:17` (restarting at the apex instead of the next index): one wasted iteration.
- `46:62`, `61:63` (collinear treated as crossing): the exact zero-turn filter removes the
  corner.
- `124` (2, extra loop iterations with nil portals): no-ops.
- `147:15` (`radius >= 0`): a zero shift.

**Not killed:**
- `46:21` (`or`→`and`): it needs a funnel whose right side sits at the apex while the next
  portal's right end lies left of the left side, which consistent portals don't produce.
- `149:44` (the half-portal cap `*0.5`→`/0.5`): it needs a portal shorter than 2r with a wall
  vertex.

## Build

**Tests added (NavMesh.Build.spec, NavMesh.Floors.spec):**
- Error level 2 for the argument errors (Floors, floor names, no floors, TileSize,
  MaxAgentRadius). Authoring errors carry no position.
- A folding ring's message names the point in studs.
- Seam errors: an unknown floor, a non-vector end, an end beyond 32,768 in X, and a seam on one
  floor's edge but off the other. Seam ends at exactly 32,768 studs in X and Z are accepted,
  and so is MaxAgentRadius 32768.
- "a U-shaped ring, whose two top edges lie on one line, builds".
- Link errors: an infinite Cost and a non-vector end. "a link defaults to its length as Cost and
  area 1, and snaps ends authored off the mesh" (0.3 off in X or Z, 3 above, 2 below).
- "a seam at 45 degrees joins its floors like any other".
- "a non-planar floor's creases never become seam portals" (added after the final gate; it
  kills `822:48`).

These are judged by reading the code; each group's reason is below. They weren't re-applied
one by one.

**Equivalent survivors:**
- `71` (2, `max(area, 1)`, `max(edges, 1)`): every floor has at least 3 edges and 1 stud² of
  area.
- `99` (6), `104` (4): the ring self-intersection test. Orientations are exact integers, so
  `< 1` equals `<= 0` and a quotient has the product's sign. The zero (touching or collinear)
  cases are decided by the separate touching test either way. The U-shape spec confirms that
  collinear, disjoint edges still build.
- `127:11`, `133` (3), `172` (2), `177` (2), `178:11`, `179:18` (reversal with `j = n - i`
  gives the reversed ring rotated by one), `208` (2), `209:10`: capacity hints, ties at
  distinct points, and loop starts.
- `220`, `224` (4, the plane fit with a sign flipped consistently), `221:13`, `226:28`:
  planarity boundaries. The creases and heights come out the same on every fixture.
- `254` (3): the unused returns of a nil surface.
- `276` (6, `pointKey`): it stays injective on grid coordinates.
- `308` (6), `309`, `310` (4), `312` (2): `clipToRect`'s crossing branch. Snap rounding with
  the tile lines means a ring never crosses a tile line between vertices (the sp and sq values
  are integers), so the branch and its guard are unreachable.
- `326`, `328` (2), `333` (4), `337:13`: deduplicating the clip output (duplicates are
  dropped by the triangulator), and a degenerate clip result that never occurs.
- `402` (3), `427` (2): initial values that get overwritten.
- `411:23`, `454:34`, `920` (3), `914` (3): tolerance boundaries.
- `431` (2), `436` (10), `437` (4), `438` (3): the nearest-centroid fallback for a point on a
  surface triangle's edge. Every candidate gives the same height there.
- `520:12`, `522:41`, `537:51`, `560:14`: loop starts, and ties on distinct keys or
  non-degenerate triangles.
- `640` (2), `648:46`, `654` (2), `672:31`, `755:23`: the crease range and filter. Extra
  edges get treated as creases, and they only duplicate edges that are already constraints
  (ring edges or tile lines) as open constraints.
- `706:33`: chain-start rotation, as in Tiles `222:33`.
- `715:22`, `731` (2), `783` (2), `784` (2), `788:24`, `791:13`: the tile index stride and
  ranges. The index stays injective, and extra rows or columns are empty or kept nothing.
- `817` (5): the midpoint-in-tile test for crease fragments. A fragment crossing a tile line
  was split there by snap rounding, so a midpoint on a border means the fragment runs along
  the border, which is a constraint already. Adding it to more tiles only duplicates it.
- `878:28`, `880` (4), `890` (4): seam parameterization. A monotone reparameterization, or any
  two distinct side labels, gives the same overlaps. The 45-degree seam killed `878:23` and
  `880:27`, the only mutants that were not monotone there.
- `900:9`: a tie at `tu == tv`, which is impossible for a non-degenerate edge.

**Not killed:**
- `151:95` (a message coordinate in Z, where the tested ring folds at z = 0).
- `756` (2), `757` (2): the crease bucketing reads the next fragment's endpoints, which puts
  the crease in the neighbouring tile's list. The tiled crease specs didn't notice. That needs
  a crease that spans several tiles, with its tile checked for the crease edge.

## Not triaged (triaged before)

Quantize, Snap, Storage, OpenList and DrawList were left as they were:
- Final gate: 85.3%, 88.5%, 93.5%, 86.7% and 97.5%.
- Snap: the new tests killed `128:51`. The two survivors the link fix exposed (above) are killed
  by the post-gate miss assertion, which puts Snap at 17 survivors, or 89.7%.
- The suite takes about 11 s uninstrumented (about 7 s before). The largest additions are the
  brute-force clearance flood (about 1.7 s) and the search oracles.

## Commands

- Gate a file: `lune run coverage.luau package=navmesh --mutate --mutate-jobs=16 --mutate-files=src/Tiles.luau`
- Whole suite: `lune run coverage.luau package=navmesh`
