# 29: Agent height (headroom)

**What to build:** Tall agents don't path where they can't stand up, such as under a low
balcony or through a duct.

**Blocked by:** Track B's v3 bake format (the headroom needs a field in it; see "Format").

**Status:** needs-triage. Ruled 2026-09-28 (review.md, D2: "Core AgentHeight"). From
[research/roblox-pathfinding-comparison.md](../research/roblox-pathfinding-comparison.md)
gap G4. Roblox's version: `AgentHeight`, default 5, "Empty space smaller than this value,
like the space under stairs, will be marked as non-traversable"
(https://create.roblox.com/docs/characters/pathfinding).

- [ ] **Input:** `FloorDesc.Headroom: { { Polygon: Polygon, Height: number } }?`, rings like
      `Areas`, each giving the free height above the floor inside it.
  - Where rings overlap, the lower height wins (the safe answer). Areas use "later wins"
    instead, so document the difference.
  - Outside every ring the headroom is unlimited.
  - The Part adapter (ticket 26) computes these rings from the Parts above each floor.
- [ ] **Build:** the rings go in as their own winding groups, so every triangle lies wholly
      inside or outside each ring. Each triangle stores its headroom (one f32 per triangle,
      `math.huge` for none) through new Storage accessors, with a Storage-contract case.
- [ ] **Query:** `QueryFilter.AgentHeight: number?` (default 0 = ignore). Search treats a
      triangle with headroom under `AgentHeight` like an excluded area.
  - The same filter applies in `FindNearestPoint`, `FindRandomPoint`, `Raycast` and
    `MoveAlongSurface`, following whatever each already does for an excluded area.
- [ ] **Open question (rule in the ticket):** should another floor overlapping above set
      headroom automatically?
  - Its *surface* height overstates the gap by the slab's thickness, which we don't know. So
    automatic headroom is unsafe unless the author gives a thickness.
  - Recommendation: no. The adapter knows the Parts, so it emits explicit rings instead.
- [ ] **Clearance:** walls only, as today (SR4). A low-headroom region is not a wall, so a big
      agent's body can overhang its edge, as it can at an excluded area's edge. Document it,
      and don't change clearance.
- [ ] **Dynamic obstacles** have no height, and stay full-height cut-outs. `Update` must keep
      headroom on rebuilt tiles: the rings go into each tile's baseline, like areas.
- [ ] **Format:** per-triangle headroom, or the rings, in the bake. Coordinate with Track B,
      and prefer storing the rings and recomputing on load if the bake-size difference
      matters (measure both).
- [ ] **Specs:** an overhang fixture where `AgentHeight` 5 goes around and 3 goes under;
      headroom kept across add-then-remove of an obstacle ("Update equals a fresh Build");
      `FindRandomPoint` never returns a point under a lower headroom; Serialize round-trip. All
      with negative controls.
- [ ] **Bench:** Search cost with and without an `AgentHeight`. It is one extra compare per
      expansion, so it should be within noise.
