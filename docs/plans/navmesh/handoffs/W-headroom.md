# Wave 2: ticket 29, agent height (after Tracks E and F merge)

Read [README.md](README.md) first. Start only once E and F have both merged: headroom touches
Build, Storage, Search, Queries, Serialize, Types and the adapter, so it collides with any
track running beside it (user ruling, 2026-10-01).

**Setup:** a worktree off `feat/navmesh`, branch `navmesh-headroom`.

## Scope
- The full spec is in `docs/plans/navmesh/tickets/29-agent-height.md`, ruled in review.md,
  research D2: "Core AgentHeight".
- **Input:** `FloorDesc.Headroom` rings. Where rings overlap, the lower height wins.
- **Query:** `QueryFilter.AgentHeight`. Search treats too-low triangles like an excluded area,
  and the other queries follow suit.
- **Adapter:** it emits the headroom rings from the Parts above each floor (ticket 26's open
  item).
- **Format:** v3 reserves a headroom field. Measure storing per-triangle headroom against
  storing the rings and recomputing on load.
- **Update:** keeps headroom on rebuilt tiles, so "Update equals a fresh Build" still holds.
- **Clearance:** unchanged. It still measures to walls only (SR4). Document that a big agent can
  overhang the edge of a low area.

## Rulings to ask for
- **Whether a floor overlapping above sets headroom automatically.** The ticket recommends no:
  a surface height overstates the gap by the slab's thickness, which we don't know. The adapter
  emits explicit rings instead.
- **The adapter's area-name table** (research D5), ticket 26's other open item. It could be
  built in the same pass, since this wave touches the adapter anyway.

## Gates
- The specs listed in ticket 29, each with a negative control.
- A bench of `FindPath` with and without `AgentHeight`; it should be within noise.
- Mutation at or above the baseline.
- Merge into `feat/navmesh`.
