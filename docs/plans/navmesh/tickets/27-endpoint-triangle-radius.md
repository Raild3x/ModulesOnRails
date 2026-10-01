# 27: AgentRadius inside the start and goal triangles

**What to build:** `FindPath` respects `AgentRadius` inside the triangle a path starts or ends
in, and when start and goal share a triangle.

**Blocked by:** none (it touches Storage, Clearance and Serialize, so rule the format question
first)

**Status:** done 2026-09-28 (Track B, branch `navmesh-v3`, commit 77fd0c3; see As built)

- [x] **Repro:** a 20 x 10 room with a wall at x 10..11, z -1..9, built as one big tile.
      `FindPath((9.6, 0, 9.5), (15, 0, 5), { AgentRadius = 0.51 })` returns Success through
      the 1-stud gap. The start triangle is the sliver (0,10) (10,9) (20,10), and leaving it
      reads its exit edge's width (1.64), not the gap.
- [x] The same holds for the goal triangle, and for start and goal in one triangle, where the
      search returns Success at once with no radius check.
- [x] **No false positives:** an oracle, such as a grid clearance flood, confirms every
      Success-to-Partial flip on the bench maps.

## Rejected prototype (2026-09-28)
- **What it was:** about 70 lines in `Search.luau`. For each exit-edge corner narrower than
  2r, a "bottleneck line" runs from that vertex to the nearest point of its opposite edge. An
  end on the far side of that line is blocked.
- **What it fixed:** the repro. Its cost was within noise.
- **Why it was rejected:**
  - It is unsound: it flipped 21 of 600 random bench queries to Partial, some with both ends
    2-3 studs clear of every wall.
  - A corner width is only a number. It can come from the short-edge bound rather than a real
    gap, and vertex-to-nearest-point is not the true gap line.

## What a sound fix needs
- Store, per triangle corner, the wall point that sets its width. Clearance finds it and
  discards it; keeping it costs 6 more numbers per triangle.
- Use the real gap segment in the side tests, and only when a wall feature sets the width.
- Touches the Storage layout, Clearance, `Update`'s width copy, and Serialize: either a v3
  format or recomputing the points on load.
- **Loose ends:** a blocked same-triangle start and goal should search for a detour, and a goal
  triangle entered across a seam needs the same check.
- **Workaround today:** a smaller `TileSize` makes such slivers rare. The FindPath gap spec
  uses `TileSize = 2`.

## As built (2026-09-28, Track B)
- **No stored data.** Neither stored option above was built:
  - one wall point per corner can't hold a chain of several walls;
  - the barrier that matters depends on the query's radius.
  The check runs at query time, in `Clearance.CutOff` (an end against the edge it leaves or
  enters by) and `Clearance.Separated` (two ends in one triangle). There is no format change
  and no `Update` work.
- **A barrier:** a component of radius-r wall discs cut to the triangle, joined where two link
  inside it (the width chain's rule).
  - A barrier with two contacts on the boundary (triangle vertices, or points on wall edges)
    gives a polygon: a covered polyline through the component, closed along the boundary away
    from the edge.
  - An end inside the polygon (odd crossings) is cut off. That is sound: the covered polyline is
    the only way across.
  - A straight clear line from the end to the edge proves it is not cut off, which is the
    common fast exit.
- **What the oracle caught while building it:**
  - *A barrier ending inside a crossable edge* doesn't close. The agent steps round its end into
    the neighbour and back across the same edge, which no corridor can hold. So contacts on a
    crossable edge count only at its vertices. Spec: "a barrier ending inside a crossable edge
    doesn't cut an end off".
  - *Leaving and coming back:* once an end is cut off from an edge, the start triangle can be
    entered again as a separate node, and so can the goal triangle, passed through.
  - *Ends touching a wall* (clearance under r, as in the repro) are judged where they stand
    pushed straight out of the nearest wall to r. If that point is still covered, its side is
    unknown and it is not cut off.
  - *Partial paths* stay on the start's side: once the start is cut off, its triangle is not
    used to pick the end point.
- **Loose ends:**
  - Same-triangle ends search for a detour through a separate goal node.
  - The goal entered across a seam is checked on the seam edge.
  - Links landing in the goal triangle are not checked (out of scope).
- **Oracle:** `tools/navmesh/bench/radius_oracle.luau`, with the grid flood in
  `Tests/Helpers/Flood.luau`. It floods liberally (a cell is free if it may hold a free point,
  with ambiguous cells split down to 0.002 studs), so "disconnected" is a proof.
  - Over random bench and notch queries (half near wall corners, half fair):
    - seed 1: 77/77 flips confirmed over 40,000 queries;
    - seed 2: 76/76 over 40,000.
  - Negative controls: an inverted test is refuted, and dropping the contact rule fails the
    specs.
- **Specs** (FindPath, "radius inside the start and goal triangles"): the repro both ways, the
  same-triangle detour and no-detour cases, the U-turn case, and a flood oracle over the notch
  room. All four fail on the old code.
- **Cost:** FindPath with a radius is +8-48% on cheap random queries (bench.md, "Ticket 27").

## Mutation (2026-09-28, rebased on tickets 23/24)
- **Covered-line scores:** Clearance 80.1 (80.9 before), Search 84.0 (85.5 before), Storage
  95.6, Tiles 80.4, Serialize 87.5, Build 83.5.
- **Survivors in the new code, triaged:**
  - *Equivalent:*
    - `x == nil or z == nil` turned to `and`: `standing` returns both or neither.
    - Loops started at 0: the index-0 entries are nil and skipped.
    - Repeated component roots, pairs of a contact with itself, and all pairs in `CutOff`: each
      gives the same or a still-sound verdict.
    - The memo's index literals (a miss is only slower) and `buildIndex`'s flag (walls are
      already flagged).
    - The sample points on `e`: any point of `e` proves a clear line.
    - Search: `width > 0` turned to `>= 0` (CutOff at r = 0 is false); the start's own push
      priority; the stamp direction; a point outside the triangle, which is never inside its
      barrier.
  - *Measure-zero boundaries:* `<` / `<=` ties in `inside`, `clear`, `standing` and the
    contact test.
  - *Unreachable on meshes we can build:* the ids of the start-again and goal-again nodes.
    Through a sliver, the gap's own corner width blocks passing from one crossable edge to the
    other, so the pass-through node is a dead end whatever it maps to (checked by hand for four
    mutants).
- **Specs added for the real ones:**
  - pushed-out and uncovered ends;
  - a same-triangle pair with no clear line;
  - detour and pass-through corridors checked via `Search.Run`;
  - the per-mesh memo, queried in both orders;
  - a lone-triangle Partial;
  - a pinned count and hash of cut-off and parted verdicts over fixed queries.

## Partial and Budget ends (2026-10-01, Track G, G3)
- **The gap:** a Partial or Budget end was its triangle's point nearest the goal, then pushed
  off the walls. It could lie past a barrier inside that triangle. Repro: ticket 27's room, from
  (5, 5) to an east-room goal at r 0.51, ended at x 14.5-18.2, past the 1-stud gap.
- **The fix, in `Search.Run`'s end selection, with this ticket's code only:**
  - Each best candidate is judged as FindPath will return it: pushed off the walls with
    `Queries.Push`.
  - The push can carry it out of a sliver too thin to stand in, into a neighbour. So it is
    checked in the triangle it lands in, against every node the search closed for that
    triangle (a start-again or goal-again node too):
    - `CutOff` from the node's entry edge;
    - `Separated` from the start point, or from a link's landing;
    - for a seam, `CutOff` from the seam edge.
  - A stranded candidate is skipped and the next best is taken; the start point always
    stands. The extra cost is a rescan per stranded candidate (`ponytail:` noted).
  - The tested point is moved 1/1024 stud towards its triangle's centroid, in f64. A point on
    the triangle's boundary (where the nearest point usually is) is undecided by the barrier
    polygons' even-odd test, and a point on a wall can't be pushed out.
- **Specs** (FindPath spec, ticket 27 section):
  - the room's three goals end west of the gap, a narrow agent still succeeds, and an islands
    end against a wall still stands r off it;
  - over 24 one-slab rooms with random slab place, width and gap (every barrier inside one
    triangle), every Partial and Budget end the agent can stand at is reachable from the start
    by the grid flood (67 ends judged).
- **Negative controls:** each fails a spec: no check (2 fail), no nudge (2), no push (2), no
  barrier test (2), and nodes not required to be closed (3).
- **What it still misses** (known-gaps.md):
  - an end the push leaves in the pinch itself (still under r from the walls), which `CutOff`
    can't place;
  - a barrier closed in a neighbouring triangle (this ticket's completeness gap).
  - A stricter rule was prototyped and dropped: refuse any end that can't stand clear after
    the push. It took the many-slab room to 17/405 unreachable ends, but it also refused ends
    in acute corners, which the two-pass push can't clear. Those fell back to the start: ticket
    27's lone-triangle spec failed. A many-pass push to tell corners from pinches was worse on
    every count (12% unreachable, 83 us, still failing that spec).
- **Numbers** (`tools/navmesh/bench/partial_end.luau`, many-slab rooms, 5 seeds, 405
  Partial/Budget ends): ends a flood proves unreachable went from 216 (53%) to 89 (22%). Partial
  FindPath went from 30 to 56 us mean (p95 54 to 113). Success paths don't run this code.
