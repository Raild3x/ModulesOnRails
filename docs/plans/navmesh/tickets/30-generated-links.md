# 30: Generated jump and drop links, and runtime links

**What to build:** Links generated from the mesh for ledges an agent can drop off or gaps it
can jump, plus links that can be added and removed at runtime.

**Blocked by:** none, but it touches `Search.luau`, `Tiles.luau`, `Storage.luau` and
`Serialize.luau`. Run it after Track B lands v3, or fold its format fields into v3.

**Status:** needs-triage. Ruled 2026-09-28 (review.md, D3: "Generator + runtime AddLink").
From [research/roblox-pathfinding-comparison.md](../research/roblox-pathfinding-comparison.md)
gap G3.
- Roblox generates jump links with `Label = "Jump"`, controlled by `AgentCanJump`
  (https://devforum.roblox.com/t/full-release-introducing-the-pathfinding-links-for-npcs/1771534).
- Its generator is being rewritten because it makes bad links on walled edges
  (https://devforum.roblox.com/t/navmesh-falljump-connections-are-incorrect-on-walled-edges/4645494).
- Link density and deduplication are the hard part.

## Part 1: runtime links
- [ ] `NavMesh.AddLink(mesh, desc: LinkDesc) -> number` and `NavMesh.RemoveLink(mesh, id)`,
      pending until `Update`, the same model as obstacles (SR13).
  - `Update` already re-snaps every link onto the new triangles (`Tiles.luau`, the "Links"
    pass), so a pending link joins that pass.
  - `AddLink` validates eagerly (errors at the call); snapping happens at `Update`.
  - An end that doesn't snap at `Update` fails the whole `Update` and rolls it back, as an
    invalid obstacle does.
- [ ] **Ids never reused, records freed on removal:** the obstacle v2 pattern (sparse records
      plus a next id). `SetLinkEnabled` and ticket 25's `LinkDesc.Name` work on them.
- [ ] **Stamps:** adding or removing a link bumps both end tiles, as `SetLinkEnabled` does
      (SR5), and its ends' tiles join `Update`'s `ChangedRegion` list, so ticket 28 sees them.
- [ ] **Risk, measure first:** `Search.HeuristicScale` loops over every link on every
      `FindPath` (`Search.luau`, `HeuristicScale`). With hundreds of generated links that is
      the dominant per-query cost.
  - Fix candidates: cache the scale per mesh, keyed by a link-set version and the `AreaCosts`
    table; or keep the cheapest price-per-length per link area.
  - Benchmark with 0, 100 and 1,000 links before choosing (house rule).
- [ ] **Format:** sparse link records plus the next link id. Fold into v3 if Track B hasn't
      frozen it yet, else v4.

## Part 2: the generator
- [ ] `NavMesh.GenerateLinks(mesh, options) -> { LinkDesc }`, a pure function over a built
      mesh. It returns descriptions; the caller rebuilds with them or passes each to `AddLink`.
  - Options: `Spacing` (studs between samples along a wall, default 4); `MaxDrop`;
    `MaxJumpDistance`; `MaxJumpUp`; `Clearance` (the radius the landing must admit); `Area`
    (the area id for the links, so `AreaCosts[area] = math.huge` is `AgentCanJump = false`);
    and optional `Labels`.
- [ ] **Drops:** at each sample along a wall edge, step `Clearance` outward and down. Use
      `FindNearestPoint` with a search radius on lower floors, within `MaxDrop`. Emit a one-way
      link, `Label = "Drop"`.
- [ ] **Jumps:** step outward across the gap, up to `MaxJumpDistance`, to a floor within
      `MaxJumpUp`. Emit it one-way (or bidirectional when both directions qualify), with
      `Label = "Jump"`.
- [ ] **Walled edges** (Roblox's current bug): no link when the outward step lands inside an
      obstacle or on the same floor within walking reach. It must not duplicate a walkable
      route. The rule: a link is kept only if its walking-path cost is at least `k` times the
      link's cost (default k = 2).
- [ ] **Deduplicate:** merge adjacent samples that land on the same floor within `Spacing` of
      each other, and keep one link per run.
- [ ] **Editor:** a "generate links" action draws them before they are committed.
- [ ] **Specs:** a balcony gets drop links to the floor below and none back; a walled balcony
      gets none; a 3-stud gap gets a jump link and a 20-stud gap doesn't; `AreaCosts` on the
      link area turns them off; the generator is deterministic for a given mesh. All with
      negative controls.
