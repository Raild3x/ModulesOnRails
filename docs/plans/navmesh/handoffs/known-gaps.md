# NavMesh known gaps and deferred items (2026-10-01)

Read this before touching `Search`, `Clearance`, `Tiles` or `Serialize`. Each item names the
track that now owns it, where one does. Items without an owner are deferred until the user asks.

**Owned by a round-2 track:**
- **Links skip ticket 27's end check, and Storage link ids are dense:** Track E.
- **Update time grows badly with one huge authored ring:** Track F.

**Narrowed by Track G (2026-10-01):** a Partial or Budget end is now judged with ticket 27's
barriers, as FindPath returns it (pushed off the walls). See ticket 27's "Partial and Budget
ends" section. Two kinds of end still pass unjudged; both are below.

## Deferred, only if the user asks
- **Precise `IsPathValid`.** Ticket 22 notes what `Clearance.Refresh` already knows.
- **Opt1's in-place commit for `Update`.** It only matters if the remaining O(T) copy shows up;
  see ticket 22.
- **Out of scope per spec.md:** multithreading, crowd avoidance and async search.
- **Tooling chore:** stylua drift remains in `tools/coverage` (`Engine.luau`,
  `OpenCloudRunner.luau`, `modules_on_rails.luau`, `adapters/Tests/run.luau` and three core
  specs). Format it in a formatting-only commit. Never reformat the engine's test fixtures or
  goldens.

## Known gaps left by Track B (2026-10-01)
None of these are wrong answers today, but each is a place where the mesh is weaker or slower
than it looks. Read them before touching `Search`, `Clearance`, `Tiles` or `Serialize`.
- **Update time grows badly with one huge authored ring.**
  - This predates Track B; old and new code are within noise.
  - A crate near a walkable outline of 2,048 points takes 1.6 s to add at TileSize 8, and 5.0
    s at TileSize 32. At 512 points a remove spent about 270 of 275 ms in
    `Clearance.Refresh`.
  - Measure Refresh's reach rule and the wall-index churn on long rings first. Re-snapping the
    whole ring is the smaller part: about 19 ms for a planar 8,192-point ring, marked
    `ponytail:` in `Tiles.reSnap`, with a per-ring edge index as its upgrade path.
- **Links skip ticket 27's end check.**
  - A link that lands in the goal triangle, or starts in the start triangle, doesn't check that
    the agent can get between the link point and the end. Barriers are only checked across
    edges and seam portals.
  - Leaving a triangle entered by a link or a seam reads the exit edge's portal width only, as
    the start did before ticket 27; the landing point itself is never checked.
  - Ticket 30 (runtime and generated links, on `research/roblox-pathfinding`) will make links
    far more common, so fold this in there.
- **Barrier completeness (ticket 27 is sound, not complete).** It misses:
  - a pocket closed by a loop inside one component;
  - a chain between two edges that cuts a corner off without reaching a vertex;
  - a second barrier when the first one found doesn't hold the end;
  - any barrier ending inside a crossable edge. That one is deliberate: no corridor holds the
    U-turn round it.
  Each miss falls back to the old optimistic answer. The search's start-again and goal-again
  node ids have no spec that reaches them; no mesh built so far needs them (ticket 27's
  mutation notes).
- **A Partial or Budget end can still lie past a gap narrower than 2r** (narrowed by Track G).
  - Since Track G, each candidate end is pushed off the walls, then checked with
    `Clearance.CutOff` / `Separated` in the triangle the push lands in. A stranded one is
    skipped for the next best.
  - Two kinds of end still pass:
    - **An end the push leaves inside the pinch itself**, still under r from the walls.
      `CutOff` can't place a point that can't stand, so it answers "not cut off". A stricter
      rule was tried: refuse an end that can't stand clear. It also refused ends in acute
      corners, which the two-pass push can't clear, and dragged them back to the start.
    - **A barrier closed in a neighbouring triangle**: the wall that closes it is more than r
      from the end's triangle. This is ticket 27's "barrier completeness" gap.
  - On the many-slab room (`tools/navmesh/bench/partial_end.luau`), ends a grid flood proves
    unreachable went from 216 of 405 to 89. Partial FindPath there went from 30 to 56 us mean.
- **A loaded mesh pays an O(triangles) spike once.** After `Deserialize`, the first `Update`
  or the first `FindPath` with an `AgentRadius` builds the wall index. Bake it, or build it
  lazily per tile, if load-time hitches matter.
- **Link ids are dense in Storage.** v3 bakes carry link ids and a next id, but the reader
  still requires ids 1..n. Ticket 30's sparse ids need Storage link ids first, then this
  reader check relaxed. The format itself needs no change.
- **FindPath with a radius costs 15-40 us more,** mostly gathering the walls around the start
  and goal triangles (bench.md, "Ticket 27"). The last answer is memoized per mesh. Cache per
  triangle if radius queries get hot.
- **The old-sources oracles need a hand-made copy.** `tools/navmesh/bench/radius_oracle.luau`
  and `findpath_radius_cost.luau` compare against `lib/navmesh/src_old`, made with
  `git archive <base> lib/navmesh/src`. Keep it out of the tree during coverage runs.
- **Scratch archive:** the old `navmesh-phase0` worktree's untracked `zz_*` probes are in the
  main checkout's gitignored `.bench/navmesh/archive/navmesh-phase0/`.
