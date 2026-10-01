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

## Part 1 as built (Track E, 2026-10-01, commit 3b4d0d5)
- **API:** `NavMesh.AddLink(mesh, desc) -> id` and `NavMesh.RemoveLink(mesh, id)`, pending
  until `Update` (SR13), as specified. `AddLink` runs Build's own link checks at the call
  (`Build.Internal.CheckLink`); `Update` snaps the ends with Build's snap
  (`Build.Internal.SnapLinkEnd`). An end that doesn't snap fails that `Update` with
  `NavMesh.Update: link <id>: To (...) is not on the mesh` and rolls back every pending change,
  obstacles too. `HasPendingChanges` covers links. A link-only `Update` keeps every triangle; it
  still pays the O(T) range copy.
- **Storage:** link records are sparse like obstacles (id, state, name, next id). Extra links
  name a link by its slot, and `RemoveLinkRecord` moves the later slots' extras down. A pending
  add has no triangles, and cost -1 when it takes the default (made from the snapped ends at
  `Update`, as Build does).
- **Stamps and regions:** `Update` bumps every link end's tile (as before). It also returns the
  end tiles of each link it added or removed as changed regions, so `FirstAffectedSegment` sees
  them (ticket 28).
- **Format:** still v3, with no new version. The links section writes real ids and the next id;
  flags 4 and 8 mark a pending add or removal. Names go in a new optional section, 0x0001,
  written only when a link has a name. A bake with no names and no pending links is byte-for-byte
  what it was, so the demos needed no rebake (the frozen-bake spec passes).
- **Heuristic scale:** measured first (bench.md, "Ticket 30"). At 1,000 links the loop was 44-60
  us of a 114-170 us `FindPath`. It now reads `Storage.LinkPrices`, the cheapest Cost / length per
  link area, rebuilt after any link change: 0.08 us, and 55-95 us per `FindPath` at 1,000 links.
  There was no fork to rule: the `AreaCosts`-keyed cache breaks when a caller edits its table in
  place.
- **Ticket 25's link items:** `LinkDesc.Name`, `SetLinkEnabled` by name (every link with that
  name), `Waypoint.LinkId` and `FollowerLink.Id`. The follower and `FirstAffectedSegment` now
  key on `LinkId`. Before, a link with no `Label` gave its start waypoint nothing to mark it, so
  the follower tried to walk the gap.
- **Specs:** `NavMesh.Links.spec.luau` (16) plus a Storage contract case. There were 20 hand
  negative controls (one break each: no snap at Update, no rollback, no record freeing, stale
  prices, no regions, no names section, the reader's id check, follower on Label, ...). Each
  failed at least one spec. The reader's id check first passed, because Storage's own assert
  also rejected the bake. The spec now checks for the damaged-bake message itself.
