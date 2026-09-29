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
