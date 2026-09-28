# 27: AgentRadius inside the start and goal triangles

**What to build:** `FindPath` respects `AgentRadius` inside the triangle a path starts or ends
in, and when start and goal share a triangle.

**Blocked by:** none (it touches Storage, Clearance and Serialize, so rule the format question
first)

**Status:** needs-triage (found by the 2026-09-28 hardening; a prototype was built and
rejected)

- [ ] **Repro:** a 20 x 10 room with a wall at x 10..11, z -1..9, built as one big tile.
      `FindPath((9.6, 0, 9.5), (15, 0, 5), { AgentRadius = 0.51 })` returns Success through
      the 1-stud gap. The start triangle is the sliver (0,10) (10,9) (20,10), and leaving it
      reads its exit edge's width (1.64), not the gap.
- [ ] The same holds for the goal triangle, and for start and goal in one triangle, where the
      search returns Success at once with no radius check.
- [ ] **No false positives:** an oracle, such as a grid clearance flood, confirms every
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
