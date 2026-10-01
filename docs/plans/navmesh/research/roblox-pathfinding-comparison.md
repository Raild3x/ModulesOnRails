# Research: Roblox PathfindingService vs our NavMesh

Researched 2026-09-28 on branch `research/roblox-pathfinding` (off `feat/navmesh` at 6a26741).
Research only: nothing under `lib/` or `tools/` changed.

**Scope.** This compares Roblox's built-in pathfinding (PathfindingService, Path,
PathWaypoint, PathfindingModifier, PathfindingLink) with `lib/navmesh` as of tickets 01-24.
For each finding it names the ticket or handoff track (A-D, see
[handoffs/README.md](../handoffs/README.md)) that already covers it, and flags what is new.

## Sources and confidence

Every claim about Roblox carries a source and a confidence label.

**Confidence labels:**
- **[doc]**: create.roblox.com documentation. Reference-page descriptions were read from the
  docs' own source, `github.com/Roblox/creator-docs` (`content/en-us/...`), because the rendered
  pages drop the long descriptions.
- **[staff]**: a DevForum post by a member of the Roblox_Staff group. These count as primary
  for behaviour changes and betas, but they age.
- **[community]**: anything else. These are leads, not facts.
- **[unverified]**: we looked and found no primary source.

**Short links:**

| Key | URL |
|---|---|
| GUIDE | https://create.roblox.com/docs/characters/pathfinding |
| PFS | https://create.roblox.com/docs/reference/engine/classes/PathfindingService |
| PATH | https://create.roblox.com/docs/reference/engine/classes/Path |
| WP | https://create.roblox.com/docs/reference/engine/datatypes/PathWaypoint |
| WPA | https://create.roblox.com/docs/reference/engine/enums/PathWaypointAction |
| STATUS | https://create.roblox.com/docs/reference/engine/enums/PathStatus |
| MOD | https://create.roblox.com/docs/reference/engine/classes/PathfindingModifier |
| LINK | https://create.roblox.com/docs/reference/engine/classes/PathfindingLink |
| IMP | https://devforum.roblox.com/t/improving-pathfinding-quality-with-new-algorithm/3258657 (staff, 2024-11-14, with later staff replies) |
| RESTORE | https://devforum.roblox.com/t/pathfindinguseimprovedsearch-is-now-restored/3544692 (staff, 2025-03) |
| MODBETA | https://devforum.roblox.com/t/new-pathfinding-modifiers-studio-beta/1478034 (staff, 2021-09) |
| MODREL | https://devforum.roblox.com/t/full-release-of-pathfindingmodifiers/1651427 (staff, 2022-01) |
| LINKREL | https://devforum.roblox.com/t/full-release-introducing-the-pathfinding-links-for-npcs/1771534 (staff, 2022-04) |
| LAUNCH | https://devforum.roblox.com/t/introducing-roblox-pathfinding/55587 (official Roblox account, 2017-10) |
| SIZE | https://devforum.roblox.com/t/pathfinding-service-cannot-create-path-around-certain-objects-if-agentcanjump-is-false/3674152 (staff reply, 2025-07-29) |
| SNAPDEST | https://devforum.roblox.com/t/pathfindingservice-computed-paths-are-utterly-inaccurate/4248678 (staff reply, 2026-02-13) |
| QUEUE | https://devforum.roblox.com/t/pathfindingservice-computeasync-taking-as-long-as-20-seconds-with-useimprovedsearch-enabled/4572521 (staff replies, 2026-04) |
| EXTENT | https://devforum.roblox.com/t/pathfinding-computes-too-small-of-a-radius-around-points/1981692 (staff reply, 2024-11-19) |
| JUMPGEN | https://devforum.roblox.com/t/navmesh-falljump-connections-are-incorrect-on-walled-edges/4645494 (staff reply, 2026-05-26) |
| NEXT | https://devforum.roblox.com/t/pathfindingusesimprovedsearch-blocked-event-bug/4161369 (staff replies, 2026-01 to 2026-07) |
| CGROUP | https://devforum.roblox.com/t/pathfinding-service-is-outdated-and-does-not-recognize-newer-services/1116216 (staff reply, 2021) |

**Studio probe: not run.** Launching Studio was allowed, but nothing below needed it to rank
the gaps. The claims a probe could settle are marked [unverified]. The re-runnable probe for
them is in [Appendix A](#appendix-a-a-probe-to-settle-the-unverified-claims).

## 1. Feature matrix

| Roblox feature | Our equivalent | Notes | Source |
|---|---|---|---|
| Navmesh generated automatically from world geometry (Parts, terrain) | **none**: authored polygons (Q1); Part adapter planned | Roblox's world is the source of truth. Ours is a description the game keeps in sync. Ticket 26 / Track C covers Parts only, not terrain. | LAUNCH [staff]; GUIDE [doc] |
| Automatic regeneration when parts move ("processed in the background") | **partial**: `AddObstacle`/`RemoveObstacle`, then `Update` | Ours is explicit and atomic, and returns `ChangedRegion` boxes. Roblox's is implicit, with unknown latency [unverified]. | LAUNCH [staff] |
| Voxelized navmesh (1x1x1 grid since 2017) | exact CDT on a 1/256-stud grid | Roblox misses very thin walls (staff, 2026). We have no voxel error; the input is exact. | LAUNCH [staff]; SNAPDEST [staff] |
| `AgentRadius` (integer, default 2) | `QueryFilter.AgentRadius` (any real number, up to optional `MaxAgentRadius`) | Both use one mesh for all sizes. Ours has exact wall clearance (SR4); Roblox's has a history of "known issue" wall-cheese that ImprovedSearch mostly fixed. How Roblox quantizes the radius is [unverified]. | GUIDE [doc]; SIZE [staff]; RESTORE [staff] |
| `AgentHeight` (default 5): gaps lower than this are not traversable | **none** | No headroom concept. A floor under a low overhang is walkable for every agent. **Gap.** | GUIDE [doc] |
| `AgentCanJump` (default true): auto-generated jump links | **none automatic**. Hand-authored links; `AreaCosts` on a link's `Area` can exclude them per query | Roblox generates jump and fall links itself; the rule is being rewritten (JUMPGEN). **Gap:** no generated links. | GUIDE [doc]; LINKREL [staff]; JUMPGEN [staff] |
| `AgentCanClimb` (default false): climb TrussParts, Label `"Climb"` | hand-authored link with `Label = "Climb"` | Generating these would come with the adapter. | GUIDE [doc] |
| `WaypointSpacing` (default 4; `math.huge` = no intermediate waypoints) | **none**: waypoints at corners, links and path ends only | Ticket 25 / Track D covers this: `SamplePath(path, spacing)`, or waypoints at seams and creases. | GUIDE [doc] |
| `Costs` keyed by `Enum.Material` name or modifier `Label` (strings) | `AreaCosts` keyed by integer area id | Same idea: a multiplier on distance, and `math.huge` excludes. Roblox's string keys are friendlier. Roblox also allows negative costs as "rewards"; ours requires `>= 0`. | GUIDE [doc]; MODREL [staff]; MODBETA [staff] |
| Material costs come from world geometry for free | **none**: areas are authored rings | Covered by the adapter if it maps Material to area id (Track C, new sub-item). | GUIDE [doc] |
| `PathfindingModifier` region (Label, cost) | `FloorDesc.Areas` rings with area ids | Equivalent. Roblox's are 3D volumes; ours are 2D rings per floor. | MOD [doc] |
| `PathfindingModifier.PassThrough`: walk through collidable parts (doors) | an area ring over the doorway, or `AddObstacle`/`RemoveObstacle` per door state | Equivalent. Ours is per query (enemies can exclude the door area) with no rebuild. | MOD [doc]; GUIDE [doc] |
| `PathfindingLink` (Attachment0/1, `IsBidirectional`, `Label`) | `LinkDesc` (`From`, `To`, `Bidirectional`, `Label`, `Cost`, `Area`) | Parity, and we add an explicit `Cost` and `Area`. Roblox's links move with their attachments; ours are fixed at Build. | LINK [doc]; LINKREL [staff] |
| Enabling or disabling a link | `SetLinkEnabled` (by index) | No documented enable property on PathfindingLink [unverified]. Ticket 25 adds a link `Name`. | LINK [doc] |
| `PathWaypoint { Position, Action, Label }`; `PathWaypointAction` Walk/Jump/Custom | `Waypoint { Position, Floor, Label }` | We have no `Action` enum; `Label ~= nil` means a link. We carry `Floor`; Roblox doesn't. Ticket 25 adds the link id. | WP [doc]; WPA [doc] |
| `PathStatus`: `Success`, `NoPath`, and deprecated `ClosestNoPath`, `ClosestOutOfRange`, `FailStartNotEmpty`, `FailFinishNotEmpty` | `Success`, `Partial`, `Budget`, `NoStart`, `NoGoal` | Ours are richer and documented. Roblox's partial path needs the undocumented `PathSettings.SupportPartialPath` plus ImprovedSearch, and returns the still-deprecated `ClosestNoPath`. | STATUS [doc]; IMP [staff] |
| Partial path, "best effort" | `Partial` (optimal: closest reachable point in 3D) plus `GoalFallback` | We are ahead. | IMP [staff] |
| `Path.Blocked(waypointIndex)` / `Unblocked(waypointIndex)` events | `IsPathValid` (per tile stamp), plus `Update` returning `ChangedRegion` boxes | Roblox pushes a waypoint index to the game. We make the game poll and test boxes itself. **Gap** in ergonomics, not capability. | PATH [doc]; GUIDE [doc] |
| Guide's re-path rule: recompute only if `blockedIndex >= nextWaypointIndex` | none built in; ticket 23's follower plans a `"Blocked"` event | See gap 2. | GUIDE [doc] |
| `ComputeAsync` yields; server-wide FIFO queue; 40 ms A* budget | synchronous `FindPath` with `MaxExpansions` (Q8); async is out of scope | Our queries take 0.02-0.8 ms (REPORT.md). Roblox's queue can back up for seconds under load, with no way to query it. | PATH [doc]; RESTORE [staff]; QUEUE [staff] |
| 3,000-stud line-of-sight cap; around 20,000-node search limit | ±32,768-stud coordinate range; `MaxExpansions` is the caller's own bound | Ours has no fixed distance cap. | GUIDE [doc] |
| Lazily generated navmesh around the query, with a limited search extent | whole mesh built or deserialized up front | Ours is deterministic. Roblox's first query to a far area can fail until the navmesh there exists. | EXTENT [staff] |
| Destination snapped to navmesh directly above or below the target | `SnapExtents` box (feet position, ties go below), `FindNearestPoint` search radius, `GoalFallback` | We are ahead: Roblox doesn't snap to the nearest point. | SNAPDEST [staff] |
| StreamingEnabled: the server sees everything; a client may fail on non-streamed targets | the mesh is plain data, identical on server and client (bake) | We are ahead for client-side pathing. There is no streaming of the mesh itself (gap 7). | GUIDE [doc] |
| Collision groups | n/a (no world input) | Roblox doesn't honour them (staff intent in 2021, never shipped [unverified]). The adapter would decide by tag or attribute. | CGROUP [staff] |
| Studio "Navigation mesh", "Pathfinding modifiers" and "Pathfinding links" visualization toggles | `NavMesh.ToDrawList` plus `DrawListRenderer` (Studio), `SvgBackend` (headless), `NavMeshEditor` | Roblox's is one click and needs no code. Ours shows more: clearance colours, tiles, seams and paths, as SVG in CI. Ticket 26 / Track C polishes it. | GUIDE [doc] |
| Water and swimming (navmesh shows where a character "might walk or swim") | none | 3D volumes conflict with Q2 (2.5D floors). See "Do not copy". | GUIDE [doc] |
| Queries other than a path (nearest point, raycast, random point) | `FindNearestPoint`, `Raycast`, `MoveAlongSurface`, `FindDistanceToWall`, `FindRandomPoint` | Roblox has none. Staff, 2026-05-19: "Navmesh editing is not on our roadmap". We are clearly ahead. | IMP #58, #143, #284 [staff] |
| Bake and ship a navmesh | `Serialize`/`Deserialize` (a versioned buffer) | Roblox has no equivalent. | none found |
| Runs outside Roblox | the cores run headless under Lune | Roblox's runs only in the engine. | none |
| Sharp turns: the improved algorithm emits 2-3 waypoints depending on sharpness | the funnel offsets only at wall corners; corner clearance is a chord (REPORT.md 9) | Ticket 25 / Track D lists "arc-midpoint waypoint on sharp turns" as optional. See improvement I1. | IMP #232 [staff] |
| An upcoming navigation overhaul (closed alpha planned for summer 2026) | n/a | No public announcement found by 2026-09-28. Re-check before making any decision that depends on Roblox's direction. | NEXT [staff]; IMP #281 [staff] |

## 2. Gaps, ranked by value to a game developer

Effort is a rough guess, not a benchmark:
- **S** is under a day;
- **M** is a ticket;
- **L** is several tickets.

### G1. The mesh comes from the world, not a second description (highest value)
- **What:** a level designer builds in Studio, and navigation follows. Today the demo authors
  its level twice (REPORT.md 12). A ramp takes three hand-written pieces.
- **Roblox:** the navmesh is generated from world geometry and terrain, and regenerates when
  obstacles move (LAUNCH [staff]; GUIDE [doc]).
- **Covered?** Partly.
  - The Parts half is **ticket 26 / Track C** (blocks, wedges, cylinders).
  - **Terrain is new.** Q1's "world-geometry extraction ... in its own package" places it
    outside the cores.
- **Fit:** the adapter emits a plain `NavMeshDesc`, so the core is untouched.
  - **Terrain:** `Terrain:ReadVoxels` over a region, then a column scan for surface voxels.
    - Each height layer becomes a floor.
    - The top faces become walkable rings (marching squares on the occupancy grid), with Y
      from the surface height.
    - The water and material grids become areas.
    - The output is dense and voxel-stepped. That is what Track D's R1/R2 simplification
      passes are for, so terrain must come after D1.
- **Effort:** Parts are **M**, already scoped. Terrain is **L**: layer splitting on caves and
  overhangs is the hard part, because Q2 needs a height field per floor.
- **Risk:** none with the spec for Parts. For terrain, overhangs and caves must split into
  floors or Build errors ("floor overlaps itself"). Voxel stair-stepping can also blow up
  triangle counts until D1 lands.

### G2. Tell the game which waypoint a change blocked
- **What:** after a door closes, the game wants "is my path blocked *ahead of me*, and where?"
  without re-testing boxes itself.
- **Roblox:**
  - `Path.Blocked(blockedWaypointIdx)` and `Unblocked(idx)`. The docs say a block may be
    "behind the agent" (PATH [doc]).
  - The guide re-paths only when `blockedWaypointIndex >= nextWaypointIndex` (GUIDE [doc]).
- **Covered?** Mostly.
  - Ticket 22 returns `ChangedRegion` boxes, and its ruled contract is that a path clear of
    them is unchanged.
  - Ticket 23 / Track A plans a `"Blocked"` event from the follower.
  - **New:** a pure helper that maps a path plus regions to the first affected waypoint index.
- **Fit:**
  - `NavMesh.FirstAffectedSegment(path, regions, radius) -> number?`, pure over plain data. It
    tests each waypoint segment, fattened by the radius, against each box on its floor. This
    is exactly the ticket 22 contract, so no new invariant is needed.
  - The follower (23) calls it with its cursor, which gives Roblox's "ahead of me" rule for
    free.
  - There is no Signal object, which keeps N1/V4 (plain functions, no agent object).
- **Effort:** **S**, on top of 22's spec machinery.
- **Risk:** none. It also answers REPORT.md 4 (199 of 200 needless repaths) without an exact
  `IsPathValid` (D3 deferred).

### G3. Automatic jump and fall links
- **What:** an NPC should drop off a balcony or hop a gap without the designer placing each
  link by hand.
- **Roblox:**
  - Links are generated automatically, with `Action = Jump` and `Label = "Jump"` (LINKREL
    [staff]), controlled by `AgentCanJump` (GUIDE [doc]).
  - The current rule: ledges "wider than 4 studs thick, or taller than 6 studs high" aren't
    jumpable. A replacement generator is in progress because the current one makes bad links
    on walled edges (JUMPGEN [staff]).
  - Stairs degrade into jump links for bigger agents (RESTORE #39 [staff]).
- **Covered?** New. The closest ticket is 26 (adapter).
- **Fit:** a generator over the *built* mesh, not the description.
  1. Walk every wall edge on every floor.
  2. Cast down (FindNearestPoint with a search radius on lower floors) and across (Raycast
     outward).
  3. Emit `LinkDesc`s with `Label = "Jump"`/`"Drop"`, one-way for drops, and an `Area` so
     `AreaCosts` can exclude them per agent. That is `AgentCanJump = false` with no new
     filter field.
  4. Rebuild with the links, or add a runtime `AddLink` (none exists; links are fixed at
     Build).
- **Effort:** **M** as a separate pass that emits a new `NavMeshDesc`. **L** with runtime
  `AddLink` and stamp handling.
- **Risk:**
  - Link density: one link per wall edge would swamp search. It needs spacing and
    deduplication, which is exactly what Roblox is still fixing.
  - Links toggled at runtime already bump stamps (SR5), and added links would need the same.
  - Generated links must not cross floors ambiguously (U-b snapping).

### G4. Agent height and headroom
- **What:** a tall agent shouldn't path under a low overhang or ducts.
- **Roblox:** `AgentHeight` (default 5): "Empty space smaller than this value, like the space
  under stairs, will be marked as non-traversable." (GUIDE [doc])
- **Covered?** New.
- **Fit, two ways:**
  - **(a) Adapter-only, no core change:** the adapter measures headroom from the Parts above
    each floor. It emits area rings bucketed by height (for example area ids for "< 4",
    "< 6", "< 8" studs), and the game excludes the buckets it's too tall for through
    `AreaCosts`. Clearance and Update are untouched.
  - **(b) Core:** a per-triangle headroom value, plus `QueryFilter.AgentHeight` checked in
    Search like area exclusion. That touches Storage, Build (floor-above lookup), Update
    (a dynamic obstacle has no height, so it stays 2D), and Serialize (v3, **Track B**).
- **Effort:** (a) **S-M**, riding on Track C; (b) **M**.
- **Risk:**
  - (a) burns area ids and interacts with authored areas: the later area wins (`AreaDesc`
    order), so a mud-under-balcony cell needs a combined id.
  - (b) conflicts with nothing in the spec, but needs the v3 format slot.
  - Neither covers dynamic overhangs.

### G5. Waypoints a mover can follow directly (spacing, slope changes, floor changes)
- **What:** `Humanoid:MoveTo` or a tween between waypoints goes under the surface on ramps
  (REPORT.md 8, repro 7).
- **Roblox:** `WaypointSpacing` (default 4 studs) inserts intermediate waypoints, and
  `math.huge` turns them off (GUIDE [doc]).
- **Covered?** Yes, by **ticket 25 / Track D2** (waypoints at seams and creases, or
  `SamplePath`).
- **Fit:** `SamplePath(mesh, path, spacing)`, a pure pass that walks each segment with the
  existing surface-height lookup. Also emit creases unconditionally, since those fix the
  under-surface bug even at spacing `math.huge`.
- **Effort:** **S-M**.
- **Risk:** none. Roblox's default of 4 would be a poor default here, because our query speed
  makes lazy sampling cheap. Keep spacing opt-in.

### G6. Named costs instead of integer area ids
- **What:** `AreaCosts = { Mud = 4, Door = math.huge }` rather than `{ [3] = 4, [7] = math.huge }`.
- **Roblox:** the `Costs` keys are material names or modifier `Label` strings (GUIDE [doc]).
  Labels and materials share one namespace (MODBETA [staff]).
- **Covered?** New. It is an ergonomics item next to ticket 25's `LinkDesc.Name`.
- **Fit:** `NavMeshDesc.AreaNames: { [string]: number }?`, stored in the bake. `readFilter`
  resolves string keys once per query, or better, with a
  `NavMesh.CompileFilter(mesh, filter)` that callers cache. Search keeps integer ids, so its
  speed doesn't change.
- **Effort:** **S**, plus a Serialize field (bundle with Track B's v3).
- **Risk:** per-query string resolution in a hot path. Measure it, or make compiling the
  filter the documented way.

### G7. Large worlds: loading only part of the mesh
- **What:** a big open world shouldn't hold (or ship to every client) the whole bake. For
  scale, the 256-stud bench map is already 581 KB (REPORT.md timings).
- **Roblox:** generates navmesh lazily around queries, with a limited search extent (EXTENT
  [staff]). It has a 3,000-stud line-of-sight cap (GUIDE [doc]). With StreamingEnabled the
  server sees everything and clients may fail (GUIDE [doc]).
- **Covered?** New. Nothing in the tickets, and it is adjacent to the Out-of-Scope async
  search (Q8).
- **Fit:** tiles are already the unit of rebuild and stamp, so the cut is natural:
  - `Serialize(mesh, { Region })` writes a tile subset;
  - `Deserialize` merges subsets. Merging relinks cross-tile neighbours through the canonical
    border vertices (SR3), which is the same relink `Update` does.
  - Missing tiles read as walls, so queries stay correct on what is loaded.
- **Effort:** **L**. Seams and links that cross a region border need a policy, and so does
  `IsPathValid` across loads.
- **Risk:**
  - SR14: ids are unstable across loads (already true across `Update`).
  - Clearance near an unloaded border is wrong unless the border is treated as unknown rather
    than a wall.
  - Needs the user's call on whether it's in scope at all (decision 6).

### G8. Links that move, and adding links at runtime
- **What:** a moving platform or elevator whose link endpoints follow a Part.
- **Roblox:** a `PathfindingLink` sits between two `Attachment`s (LINK [doc]). That the path
  follows the attachments as they move is [unverified]; the docs don't say so.
- **Covered?** New. Links are fixed at Build; only `SetLinkEnabled` exists.
- **Fit:** `SetLinkEndpoints(mesh, linkId, from, to)` re-snaps both ends, bumps both old and
  new endpoint tiles' stamps (as SR5 does), and needs no `Update`, because links live in the
  extra-link table, not in tile triangulations.
- **Effort:** **S-M**.
- **Risk:** the SR7 heuristic scales by the cheapest link cost per length, so moving a link
  can change admissibility. Recompute that scale on every move, or document it.

### Minor gaps (no ranking)
- **`Action` enum on waypoints (Walk/Jump/Custom, WPA [doc]).** `Label ~= nil` already
  carries the signal, and ticket 25 adds the link id. Skip the enum.
- **Built-in "path is blocked" detection while following** (the physics world tells Roblox).
  Ticket 23's stall and off-mesh detection covers it.
- **A one-click visualization toggle in Studio.** Ticket 26's `navmeshdebug` re-export of
  `DrawListRenderer` gets close. A Studio plugin is Out of Scope.

## 3. Improvements, and where we are already ahead

### What we could adopt
- **I1. Multi-waypoint sharp turns.**
  - Roblox's improved search "dynamically generates two or three waypoints based on the
    sharpness of the turn", where the old one "simply offset by the agent width" (IMP #232
    [staff]).
  - Our funnel's clearance at corners is a chord (1.13-1.21 studs at r = 1.5, REPORT.md 9),
    and straight stretches can pass within 0.06r of a wall on dense maps (Track D2).
  - Adopting it means one or two arc waypoints when the turn angle exceeds a threshold. That
    turns the chord guarantee into the true radius at corners.
  - **Maps to ticket 25 / D2** ("arc-midpoint waypoint", "bisector-offset funnel").
- **I2. A blocked-ahead rule as library behaviour.** Roblox's guide encodes "re-path only if
  the blocked index is ahead of the cursor" (GUIDE [doc]). Ship it inside the ticket 23
  follower and G2's helper, so games stop re-pathing every NPC on every door (REPORT.md 4).
- **I3. Say the tuning numbers out loud.**
  - Roblox documents its limits and gotchas plainly (3,000 studs, about 20,000 nodes,
    "incompatible agent parameters", and "compute when not falling"; GUIDE [doc]).
  - Our equivalents live in `spec.md`: zero-cost links make the search Dijkstra (SR7), the
    uncapped `MaxAgentRadius` cost, and chord clearance.
  - A "Limits and gotchas" section in the `NavMesh` class doc is cheap. It fits ticket 26's
    docs items (Track C).
- **I4. A "last resort" cost idiom.** Roblox recommends a high finite cost (100 or 1000) over
  `math.huge` for "only if nothing else" (GUIDE [doc]). Ours works the same way, but it isn't
  written down, and with SR7 a large multiplier is harmless. Add one doc line.
- **I5. Floor-aware start after a fall.** Roblox computes paths only when
  `FloorMaterial ~= Air` (GUIDE [doc]). Ticket 23's follower should treat "no snap below
  within `SnapExtents`" as airborne and hold, not as blocked. Otherwise a jumping NPC reports
  `Blocked`.

### Where we are already ahead
- **Speed and determinism.**
  - Ours: synchronous queries in 0.02-0.8 ms, no queue, and a bounded `MaxExpansions`.
  - Roblox: requests queue server-wide, "execution will become increasingly delayed", there
    is "no way to query ... if it is backed up", and a 40 ms A* budget (QUEUE, RESTORE
    [staff]).
- **Spatial queries Roblox doesn't have.** `FindNearestPoint`, `Raycast`, `MoveAlongSurface`,
  `FindDistanceToWall` and `FindRandomPoint`. A queryable navmesh was discussed by staff in
  2024, and editing is "not on our roadmap" (2026-05-19, IMP #284 [staff]).
- **Exact geometry.** There are no voxel misses of thin walls (SNAPDEST [staff]), and no
  integer-only radius (GUIDE [doc] types it as integer). One mesh serves any real radius,
  with walls-only clearance (SR4).
- **Clear statuses.**
  - Ours: `Partial` and `Budget` are documented, optimal and always available.
  - Roblox: partial paths are best effort and need an undocumented setting plus a Workspace
    flag, and return the deprecated `ClosestNoPath` (IMP [staff]; STATUS [doc]).
- **Off-mesh goals.** `GoalFallback` and a search radius. Roblox snaps only straight up or down
  (SNAPDEST [staff]).
- **Explicit multi-floor.** Every waypoint carries its `Floor`. Roblox's big agents turn stairs
  into jump links (RESTORE #39 [staff]).
- **Per-query door semantics.** An area plus `AreaCosts` lets enemies and allies see the same
  door differently with no rebuild. Roblox does this too via Label costs (GUIDE [doc]), so this
  is parity, not a lead. Our `ChangedRegion` boxes are more precise than Roblox's Blocked
  events, which fire even behind the agent.
- **Plain data everywhere.**
  - A bake ships in a buffer, is identical on server and client, and has no streaming holes.
  - It runs under Lune in CI.
  - It is Actor-ready (Out of Scope, but the seams exist).
- **Visual debugging beyond a viewport toggle.** Clearance colouring, tile bounds, SVG goldens,
  and a mouse editor with a live path.

## 4. Do not copy

- **Voxelizing the world.** It is the root of Roblox's thin-wall misses (SNAPDEST [staff]) and
  of its step-height compromise (SIZE [staff]). An adapter may *read* voxels (terrain, G1), but
  its output must be exact polygons fed through our snap rounding.
- **Implicit regeneration inside the core.** Roblox regenerates in the background with no
  latency contract (LAUNCH [staff]). Ours is pending-until-`Update`, which is atomic (SR13) and
  returns exactly what changed. Any "watch the Parts" behaviour belongs in the adapter layer,
  which calls `AddObstacle` and `Update` on the game's schedule.
- **Async queueing (Q8).** A server-wide FIFO with no backlog visibility (QUEUE [staff]) is
  worse than a synchronous call with a budget, when calls take well under a millisecond.
  Time-slicing stays Out of Scope.
- **Negative costs as rewards** (MODBETA #53 [staff]). They break A*'s admissibility and
  Dijkstra's correctness. SR7's heuristic scaling already has to handle cheap areas, and
  negatives would need Bellman-Ford. Keep `>= 0`.
- **One namespace for materials and labels** (MODBETA #31 [staff]). A modifier named "Water"
  silently aliases terrain water. If G6 lands, area names should be one explicit map, with
  materials mapped into it by the adapter, never implicitly.
- **Vertical-only destination snapping** (SNAPDEST [staff]). We already have better options.
- **A hard distance cap** (3,000 studs, GUIDE [doc]). `MaxExpansions` bounds the actual cost
  instead of a proxy for it.
- **Lazy, search-extent-limited generation** (EXTENT [staff]). The first query to an area can
  fail, and the fix staff give is "query nearby first". If G7 happens, loading must be
  explicit.
- **Deprecated-but-returned enum values** (STATUS [doc] versus IMP [staff]). Our string
  statuses change only through a ruling.
- **Events that fire for blocks behind the agent** without saying so up front (PATH [doc]).
  G2's helper returns an index, and the caller compares it with its cursor.
- **Swimming volumes.** 3D navigation volumes conflict with Q2 (2.5D floors). Water surfaces
  can be a floor with a "Water" area; underwater navigation is out.

## 5. Decisions needing a ruling

**Ruled 2026-09-28.** The user's words are recorded in [review.md](../review.md):

| # | Ruling |
|---|---|
| D1 | One-shot adapter only (option 1) |
| D2 | Core per-triangle headroom plus `QueryFilter.AgentHeight` (option 2), bundled with Track B's v3 format |
| D3 | Generator plus runtime `AddLink`/`RemoveLink` (option 2) |
| D4 | Pure `FirstAffectedSegment(path, regions, radius, fromSegment?)` now. `ApplyOps` and a per-Actor Signal module wait for the multithreading work (see [D4 debate](#d4-debate-signals-and-actors)) |
| D5 | Keep integer ids; the adapter exports a name-to-id table (option 2) |
| D6 | Measure first: bake size and build time on a 1-4 km map, then rule |

The options as they were presented follow. Each was a real fork where the answer changes what
gets built.

### D1. How the world keeps the mesh in sync (G1)
1. **One-shot adapter only** (ticket 26 as scoped).
   - Pros: smallest, and already planned.
   - Cons: the game still wires doors to `AddObstacle`/`Update` by hand.
2. **Adapter plus an optional watcher:** tagged Parts (by CollectionService tag or attribute)
   map to obstacles, and moves are batched into one `Update` per frame.
   - Pros: the Roblox "it just follows the world" feel, while the core stays explicit.
   - Cons: an Instance-dependent runtime module needs the Studio test path, plus a policy for
     unanchored parts. Benchmark the batch cost first.
3. **Document a recipe, ship no code.**
   - Pros: zero maintenance.
   - Cons: every game rewrites it (REPORT.md shows how that goes).

### D2. Agent height (G4)
1. **Adapter-emitted headroom areas.**
   - Pros: no core change; `AreaCosts` does the rest.
   - Cons: area-id combinations with authored areas; static only.
2. **Core per-triangle headroom plus `QueryFilter.AgentHeight`.**
   - Pros: exact, and one filter field like Roblox's.
   - Cons: Storage, Build and Serialize v3 changes (coordinate with Track B); dynamic
     obstacles have no height.
3. **Not supported:** authors split floors or use areas by hand.
   - Pros: nothing to build.
   - Cons: a common Roblox expectation goes unmet.

### D3. Generated jump and drop links (G3)
1. **An offline generator pass that emits `LinkDesc`s** before Build (a tool or adapter
   function).
   - Pros: no core change, and the result is inspectable in the editor.
   - Cons: static; rebuild to change.
2. **A generator plus runtime `AddLink`/`RemoveLink`** in the core.
   - Pros: works with dynamic geometry.
   - Cons: new link lifecycle, stamp rules and SR7 heuristic recompute.
3. **Hand-authored only** (today).
   - Pros: fully predictable.
   - Cons: authoring cost on vertical levels.

### D4. How change notifications reach the game (G2)
1. **A pure `FirstAffectedSegment(path, regions, radius)` helper,** used by ticket 23's
   follower.
   - Pros: plain functions (N1/V4), trivially testable, and matches ticket 22's contract.
   - Cons: the game still loops over its paths after `Update`.
2. **A Signal on the mesh or follower** (`Blocked:Connect`).
   - Pros: Roblox-familiar.
   - Cons: puts an object and callbacks into plain-data state, against N1/U1, and it can't
     be serialized.
3. **Nothing new:** games test the `ChangedRegion` boxes themselves.
   - Pros: zero API.
   - Cons: each game reimplements the segment and box test.

### D5. Named areas (G6)
1. **`NavMeshDesc.AreaNames` plus a cached compiled filter.**
   - Pros: readable filters, and the adapter maps Materials to names.
   - Cons: a bake field and one more concept. Measure string resolution cost if it isn't
     compiled.
2. **Keep integer ids;** the adapter exports a name-to-id table as plain data.
   - Pros: zero core change.
   - Cons: callers still write `[3] = 4`.

### D6. Is "large worlds" in scope (G7)?
1. **Out of scope** (add it to spec.md's list with the reason).
   - Pros: honest, with no speculative work.
   - Cons: 1-4 km open worlds must hold the full bake.
2. **Region bakes:** tile-subset `Serialize` and a merging `Deserialize`.
   - Pros: the tile model already fits.
   - Cons: an L-sized effort; border clearance and cross-region seams need rulings.
     Benchmark bake size per km² first.

### D4 debate: Signals and Actors
The user asked whether a Signal (cheap to consume) and Actor/multithreading support can
coexist. A subagent argued against the pure-helper position. The outcome:

- **What is incompatible:**
  - a Signal or connection stored in the mesh or a `PathResult`. It holds functions, so it
    breaks U1/N1, `Serialize`, `Actor:SendMessage` and SharedTable;
  - a Signal meant to span Actors. Each Actor is its own VM, so each Actor needs its own
    Signal.
- **What works:** an Actor-local Signal fired over the plain `{ ChangedRegion }` that `Update`
  returns.
- **A Signal is not cheaper.** The only real saving is skipping unaffected paths, and a
  bounding-box prefilter per path, O(paths x regions), gets that as plain data.
- **Multithreading means replaying a log of changes, not shipping regions.**
  1. The owner commits `AddObstacle`/`Update` first. Broadcasting before the commit would let
     replicas diverge from the owner if the owner's `Update` rolls back (SR13).
  2. The owner then broadcasts plain change records.
  3. Each Actor replays them on its own copy in parallel.
  4. `Update` is deterministic, so every copy yields the same regions. Obstacle ids come from
     the bake's next-id counter, so a replay can assert them to catch divergence.
- **Built now:** only `FirstAffectedSegment` with the `fromSegment` cursor (Roblox's "blocked
  ahead of me" rule). `ApplyOps`/`Live` wait for the multithreading work.

## Appendix A: a probe to settle the unverified claims

Not run. It is repeatable with the existing tooling (`tools/navmesh/studio/studio.py`,
`capture.ps1`).

1. **Scene.** Build the dogfood level from Parts, using `examples/navmesh-demo/StudioDemo`'s
   `buildLevel` Parts: ground, wall with door gap, crates, ramp and balcony. Add:
   - a 0.2-stud-thick wall (thin-wall miss);
   - a 3-stud-high overhang (AgentHeight);
   - a 1.5-stud gap (radius quantization).
2. **Paths.** From a server Script, for `AgentRadius` 1, 1.5, 2 and 2.5 and `AgentHeight` 3 and
   5, call `PathfindingService:CreatePath(params):ComputeAsync(a, b)` for the demo's fixed
   start and goal pairs. Log the status, the waypoints and each waypoint's `Action`/`Label`.
3. **Ours.** Run `NavMesh.FindPath` on `Level.luau` with the same radii and log the same way.
4. **What each line settles:**
   - whether a 1.5 radius behaves like 1 or 2 (quantization);
   - whether the 0.2-stud wall is crossed;
   - whether the overhang is excluded at height 5;
   - regeneration latency: move a crate, then poll `ComputeAsync` every frame until the path
     changes, and log the frame count.
5. **Capture.** Use `capture.ps1` with the Navigation mesh visualization on, and draw ours with
   `DrawListRenderer`, side by side.
