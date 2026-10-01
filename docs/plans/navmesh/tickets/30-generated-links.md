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
- [x] `NavMesh.GenerateLinks(mesh, options) -> { LinkDesc }`, a pure function over a built
      mesh. It returns descriptions; the caller rebuilds with them or passes each to `AddLink`.
  - Options: `Spacing` (studs between samples along a wall, default 4); `MaxDrop`;
    `MaxJumpDistance`; `MaxJumpUp`; `Clearance` (the radius the landing must admit); `Area`
    (the area id for the links, so `AreaCosts[area] = math.huge` is `AgentCanJump = false`);
    and optional `Labels`.
- [x] **Drops:** at each sample along a wall edge, step `Clearance` outward and down. Use
      `FindNearestPoint` with a search radius on lower floors, within `MaxDrop`. Emit a one-way
      link, `Label = "Drop"`.
- [x] **Jumps:** step outward across the gap, up to `MaxJumpDistance`, to a floor within
      `MaxJumpUp`. Emit it one-way (or bidirectional when both directions qualify), with
      `Label = "Jump"`.
- [x] **Walled edges** (Roblox's current bug): no link when the outward step lands inside an
      obstacle or on the same floor within walking reach. It must not duplicate a walkable
      route. The rule: a link is kept only if its walking-path cost is at least `k` times the
      link's cost (default k = 2).
- [x] **Deduplicate:** merge adjacent samples that land on the same floor within `Spacing` of
      each other, and keep one link per run.
- [x] **Editor:** a "generate links" action draws them before they are committed.
- [x] **Specs:** a balcony gets drop links to the floor below and none back; a walled balcony
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

## Part 2 as built (2026-10-01, branch `navmesh-links-gen`)
- **Code:** `lib/navmesh/src/Generate.luau` (the pass), `NavMesh.GenerateLinks` (a wrapper that
  hands it `FindPath` for the walk test), `Types.GenerateLinksOptions`.
- **How it works:**
  1. Every wall edge is sampled every `Spacing / 4` studs, at the middles of equal pieces.
  2. From each sample the pass probes straight out from the wall: first 0.05 studs out, then
     every 0.5 studs up to `MaxJumpDistance`. Each probe column is tested against every floor's
     triangles (`Snap.TilesIn` + `Snap.ClosestOnTriangle`). The first column with a surface
     between `MaxDrop` below and `MaxJumpUp` above the sample is the landing; the highest such
     surface wins.
  3. **Walled edges:** a column inside the ledge floor's own walkable rings, with no triangle
     of that floor, is its obstacle. The probe stops there, with no link. So a railing, an
     interior wall, or a dynamic obstacle added by `Update`, never drops through to the floor
     below.
  4. **Ends:** the landing moves `Clearance` further out when that floor is there (a drop goes
     straight down). Both ends are then pushed `Clearance` off the walls (`Queries.Push`) and
     must admit it (`Queries.DistanceToWall`).
  5. **Labels:** a landing lower than the ledge, found within `Clearance` of it, is a one-way
     `Drop`. Anything else is a `Jump`, two-way when the way back is within both `MaxJumpUp`
     and `MaxDrop`.
  6. **Dedupe, then detour:** candidates are kept greedily in triangle and edge order. One is
     dropped when both its ends lie within `Spacing` of a kept link between the same floors
     (either way round for a two-way link). Then it is dropped when the walk between its ends
     at radius `Clearance` is shorter than `DetourFactor` (default 2) times the link's length.
     The walk is `min(Length, Cost)` of `FindPath`: both are lengths of real walks (see the
     funnel finding below).
- **Defaults:** `Spacing` 4, `MaxDrop` 10, `MaxJumpDistance` 6, `MaxJumpUp` 3, `Clearance` 1,
  `Area` 1, `DetourFactor` 2, labels `"Drop"` and `"Jump"`.
- **Options are validated at the call**, with `NavMesh.GenerateLinks:` errors that name the
  caller's line. A `Clearance` above the mesh's `MaxAgentRadius` is an error too.
- **Editor:** `G` proposes links for the built mesh at `Clearance` = the agent radius, and draws
  them as orange arrows on a `ProposedLinks` layer, with the count in the status bar. `Enter`
  appends them to the description's `Links`. Any other edit drops the proposal.
  - It edits the description rather than calling `AddLink`/`Update`, because the editor's
    output is the description (export, bake).
  - The state events are `EditorState` `ProposeLinks` and `CommitLinks`.
- **Numbers (Lune, this machine):**

  | Scene | Links | Time |
  |---|---|---|
  | balcony 20 x 10 at y = 5 over ground | 15 drops | 1.4 ms |
  | `ThreeFloorStairs` | 7 drops (3 off the ramp's side, 4 off the mezzanine) | 2.4 ms |
  | 3-stud gap between two 10 x 10 pads | 2 two-way jumps | 0.6 ms |
  | `LargeMaps` city 512 (roofs at y = 12), `MaxDrop` 10 / 14 | 71 / 389 drops | 164-226 ms |
  | `LargeMaps` city 1024, `MaxDrop` 10 / 14 | 148 / 822 drops | 0.6-0.8 s |

  Every generated set builds when passed back in `NavMeshDesc.Links`.
- **Gates:**
  - `NavMesh.Generate.spec.luau`: 19 specs. The navmesh quick run passes 316/316, and
    `lune run coverage.luau package=navmesh` passes.
  - `navmeshdebug` (Studio runner): 47/47.
  - Mutation (`--mutate-files=src/Generate.luau,src/NavMesh.luau`): Generate **90.1%**
    (128 detected, 14 survived), NavMesh **94.9%** (baseline 94.7).
    - Triage of Generate's survivors, all equivalent: `FIT` 0 (the push lands exactly at the
      radius in the specs); ties on the crossing test (a probe exactly on a ring vertex); the
      unused Y of the probe point and of an empty result; initial values that are overwritten
      before use; a floor-0 scan that has no tiles; two floors at exactly the same height in
      one column; `<` vs `<=` at the detour and end-width thresholds (measure-zero ties); a
      sample at `i = 0`, which falls off the edge's end and is deduplicated away.
    - The first run scored 66.7%. The specs it led to: boundary reach limits, Clearance 0.5
      landings, a cliff foot within Clearance, a level hop, one sample at mid-edge, a runtime
      wall, a slanted balcony, and error levels for every option. It also simplified the code:
      the crossing test lost its edge margin, the probe direction is two numbers, and the walk
      no longer passes `SnapExtents`.
  - The 1-km city timings ran with another session's lune load on the machine.
- **Negative controls run** (each failed its spec, then was restored):
  - no walled-edge stop: the walled-balcony and interior-wall specs fail;
  - every link two-way: the balcony and one-way-jump specs fail;
  - the probe ignoring `MaxJumpDistance`: the 20-stud gap spec fails;
  - links not given `Area`: the `AreaCosts` spec fails;
  - random sample positions: the determinism spec fails;
  - no dedupe: the long-ledge spec fails;
  - no detour test: the bridge spec fails;
  - no end-width check: the `Clearance` spec fails;
  - never a `Drop`: the balcony, ledge and `Labels` specs fail;
  - editor: proposals not dropped on an edit, `G` making no event, and proposals drawn on the
    `Links` layer each fail their spec.
- **Finding, the funnel at a seam line:** in `ThreeFloorStairs`, `FindPath` from the ramp
  (10.5, 0.25, 3) to Ground just past the ramp's side (10.5, 0, 5.05) crosses the seam at
  x = 10 and then crosses x = 10 again on Ground, under the ramp. The funnel puts a corner at the
  seam's end (10, 0, 0) and returns `Length` 8.1 (6.2 at radius 1); the shortest walk is about
  2.3. `Cost` is 4.2. This looks like a funnel case with two collinear portals crossed in
  opposite directions. Not fixed here (Funnel is Track G's); the generator works round it with
  `min(Length, Cost)`.

### Design questions for a ruling
**Ruled 2026-10-01 (review.md, "Rulings during Track E"):** 1 keep `Area` 1; 2 one link per
`Spacing`, as built; 4 keep the defaults. Question 3 is open: the user asked whether obstacles
should get a height (their top acting as a floor). Note: since Part 1, links no longer cost a
per-query loop in `Search`, so question 2's cost argument is gone.

1. **The default `Area`.** It is 1, the same as `LinkDesc`, so generated links share area 1
   with the ground and `AreaCosts` can't exclude them until the caller sets `Area`.
   - **Keep 1:** consistent with `LinkDesc`; but "can't jump" needs a non-default option.
   - **Require `Area`:** an error without it. Explicit, but more typing on every call.
   - **A fixed default id, for example 255:** exclusion works out of the box. But it is a magic
     number that may collide with a game's own area ids.
2. **What "one link per run" means.** As built, kept links are at least `Spacing` apart, so a
   40-stud ledge gets about 10 links (`Spacing` 4).
   - **Keep:** an agent never walks more than about `Spacing` along a ledge to its link.
   - **One link per straight ledge:** far fewer links, which is cheaper for `Search`'s
     per-query link loop (Part 1's measure). But an agent may walk a whole ledge to reach its one
     link, and the detour test can't fill the gap, because it only sees links already in the
     mesh.
3. **Obstacles of other floors.** Only the ledge floor's own obstacles stop the probe.
   Obstacles have no height, so the probe can't tell a low railing from a wall.
   - **Keep:** a jump can pass over another floor's obstacle (for example a low wall at the
     foot of a cliff) and land behind it.
   - **Stop at any floor's obstacle within the height window:** safer, but it would also
     block drops past the building footprints that the Part adapter cuts out of the ground
     below a roof.
4. **The default reach numbers** (`MaxDrop` 10, `MaxJumpDistance` 6, `MaxJumpUp` 3,
   `Clearance` 1) are guesses near Roblox's defaults (jump height about 7, "ledges wider than 4
   studs or taller than 6 aren't jumpable"). Rule them, or tie them to a character.

