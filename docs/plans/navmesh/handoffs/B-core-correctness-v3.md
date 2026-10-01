# Track B: core correctness, ticket 27 and the Update pixel mismatch (one v3 format)

Read [README.md](README.md) first for the house rules and the parallel map. Both items need
data the bake doesn't hold today, so they share one Serialize format bump: v2 to v3. The
package is unpublished, so a bump is cheap. Per SR9, v2 bakes must then fail with a clear
"rebuild this bake" message, as v1 does now. Re-freeze the snapshot in `NavMesh.Serialize.spec`
and rebake `examples/navmesh-demo/Baked.luau` with its `bake.luau`.

**Setup:** start a worktree off `feat/navmesh` (for example branch `navmesh-v3`).

**Conflicts:**
- Track A edits `Search.luau` for ticket 24's goal fallback. Rebase onto A's merge before landing
  B's Search changes, or coordinate through the user.
- The simplification ring pass (Track D) will later want its epsilon in the bake too. Leave
  room: a versioned header with a field list, not a fixed layout, is enough.

## B1. Update and a fresh Build can differ by one grid pixel (do this first)

- **What:** where a *dynamic* obstacle crosses a *static* edge, `Update` re-snaps the tile's
  already-snapped baseline, while `Build` snaps the original input. The crossing can therefore
  round to the neighbouring 1/256 pixel.
  - Dates from ticket 18, not 22.
  - None of the spec fixtures or bench maps hit it.
  - A random sliver search hit it in 79 of 300 cases.
- **Evidence:**
  - `tools/navmesh/bench/zz_search2.luau` in the `update-proto` worktree is the random sliver
    search. Its "old" mode needs a copy of the old sources.
  - `zz_oracle_proto.luau` in the same folder is the bench-map "Update equals a fresh Build"
    oracle, now 48/48.
  - Port what you need into real specs or `tools/navmesh/bench`.
- **Likely fix (ticket 22's notes):** keep each tile's *unsnapped* static input, so `Update`
  snaps exactly what `Build` snapped.
  - That costs memory per tile, and it must round-trip through Serialize, hence v3.
  - **Measure the memory and bake-size cost first.** If there's a real fork (for example, store
    the unsnapped input, or re-snap from the original description the caller keeps), present
    options with numbers.
- **Gate:** the random sliver search reaches 0 of N mismatches, as a committed spec over a fixed
  seed set, with the old code failing it. The existing Update oracles stay green.
- **Background:** ticket 22's as-built notes (the "Open" section) and ticket 18.

## B2. Ticket 27: AgentRadius inside the start and goal triangles

- **What:** `FindPath` ignores the radius inside the triangle a path starts or ends in, and when
  both ends share a triangle.
- **Repro:** a 20 x 10 room with a wall at x 10..11, z -1..9, built as one big tile.
  `FindPath((9.6, 0, 9.5), (15, 0, 5), { AgentRadius = 0.51 })` returns Success through a
  1-stud gap. The full write-up is in `docs/plans/navmesh/tickets/27-endpoint-triangle-radius.md`.
- **A prototype was rejected:** a "bottleneck line" from a vertex to the nearest point on the
  opposite edge. It was unsound: it flipped 21 of 600 random bench queries to Partial, some with
  both ends 2-3 studs clear of every wall. Don't repeat it.
- **The sound design (from ticket 27):**
  - store, per triangle corner, the wall point that sets its width. Clearance already finds it
    and discards it; keeping it costs 6 numbers per triangle;
  - use the real gap segment in the side tests, and only when a wall feature sets the width.
  - It touches the Storage layout, Clearance, `Update`'s width copy in `Tiles.luau`, and
    Serialize (v3), or recomputing the points on load. **Measure both and present the choice.**
- **Loose ends:**
  - a blocked start and goal in one triangle should search for a detour;
  - a goal triangle entered across a seam needs the same check.
- **Gate:** the repro becomes a spec, with a negative control. Add an independent oracle (for
  example a grid clearance flood) that confirms every Success-to-Partial flip over random bench
  queries: 0 false positives. Mutation on Clearance, Search and Storage stays at or above its
  current score: Clearance 80.9%, Search 85.5%, Storage 95.3%.

## B3. Leave room in v3 for two later fields (added 2026-09-28)
Rulings D2 and D3 (review.md) add bake data that v3 should expect, even if these tickets land
later:
- **Ticket 29, agent height:** per-triangle headroom (one f32 per triangle), or the
  `FloorDesc.Headroom` rings recomputed on load.
- **Ticket 30, runtime links:** sparse link records plus a next link id, the obstacle v2
  pattern.

You don't need to build either. Make the v3 header a versioned field list (already asked for
above), so both can be added without a v4 that breaks bakes. If that isn't practical, say so
before v3 is frozen.

## When done
- **Docs:** record rulings in `review.md`, amend SR9 and SR4 in `spec.md`, add as-built notes
  to tickets 27 and 22, and bench numbers in `bench.md` if cost changed.
- **Merge:** into `feat/navmesh` after A's merge (or rebased onto it).
