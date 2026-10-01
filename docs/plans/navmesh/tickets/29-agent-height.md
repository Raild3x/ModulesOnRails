# 29: Ceilings and agent height (crouching, sloped and moving ceilings)

**What to build:** NPCs of different heights path according to the space above the floor.
- A 5-stud NPC that can crouch to 3 studs prefers to stay upright, crouches only when the
  detour costs more, and tells the game where it crouches and stands.
- A 2-stud NPC is unaffected.
- Ceilings come from the level's ordinary obstacles. Nobody marks "low ceiling" places by
  hand, they can slope, and they can move at runtime (a lowering platform).

**Blocked by:** none technically (the v3 bake reserves a headroom field). The handoffs
schedule it as wave 2, after the links (E) and geometry-input (F) tracks, because it
touches Build, Storage, Search, Queries, Serialize, Types and the adapter.

**Status:** needs-triage, **parked.** Revisit the design below with the user before starting.
It came out of a design conversation on 2026-10-01 and has not been prototyped or benchmarked.
- **Rulings it builds on:** review.md, research D2 ("Core AgentHeight").
- **Origin:** gap G4 in
  [research/roblox-pathfinding-comparison.md](../research/roblox-pathfinding-comparison.md).
- **Roblox's version:** a single `AgentHeight` (default 5) that marks smaller spaces
  non-traversable (https://create.roblox.com/docs/characters/pathfinding). This design goes
  further, with postures, costs and posture-change events.

## The design so far (2026-10-01 conversation)

### 1. Headroom is a measured number, not a zone
- **Rejected: "low ceiling" zones or areas.** A low ceiling is subjective: the same 3.5-stud
  gap is a crouch for one NPC and nothing for another.
- **What's stored:** each triangle stores how much free height is above it, a plain number in
  studs. Each NPC decides at query time what that number means.
- **Why not areas:** areas could approximate this today (a "low ceiling" area id, with per-NPC
  `AreaCosts`). It breaks because a triangle has one area id (mud under a low ceiling can't be
  both), and because every height cutoff needs its own area, fixed when the level is built.

### 2. Each NPC lists its postures
- **Shape:** a per-query posture list, for example:
  `Postures = { { Height = 5, Cost = 1 }, { Height = 3, Cost = 2.5, Label = "Crouch" } }`
  - It replaces the earlier single `QueryFilter.AgentHeight`.
  - In each triangle the search uses the **tallest posture that fits** and multiplies its cost
    with the area cost.
  - Where no posture fits, the triangle is excluded.
- **Cost:** standing speed ÷ posture speed, so paths minimise travel time and crouch only when
  the detour is slower.
- **Short NPCs:** a 2-stud NPC lists only `{ Height = 2, Cost = 1 }`, so its costs are
  today's.
- **Heuristic:** posture costs are ≥ 1, so the search's distance estimate (SR7) stays valid.
- **Cost of the search:** a loop over 2-3 postures per expansion. Measure it; it should be
  within noise.

### 3. The game learns where the posture changes
- **Waypoints:** `FindPath` emits a waypoint wherever the path crosses from one posture to
  another, tagged with the posture's `Label`. It uses the same mechanism as ticket 25's
  seam and crease waypoints.
  - Headroom boundaries are mesh edges, so the crossing points are exact.
- **Follower:** the follower (ticket 23) raises a posture-change event, the way it raises the
  `Link` event. The game swaps the animation and speed on it, and can start the crouch a set
  distance ahead.
- **Optional:** a `GetHeadroom(mesh, position)` point query, for NPCs not following a path.
- **The game's side:** animations, actual speeds, transition time, and smoothing (merge a short
  stand-up between two crouch stretches).
- **Later:** a per-change penalty in the search, if transitions take real time.

### 4. Ceilings come from obstacles
- **Rejected: a separate "ceiling" concept.** That meant ceiling objects with ids
  (`AddCeiling`/`SetCeilingHeight`) and their own bake section, which is too much new surface.
- **The adapter already does this, for one height.** `NavMeshAdapter`'s `cut` treats every
  Part as a convex 3D solid, with full CFrame rotation, so yaw, pitch and roll all work. It
  slices the solid between the floor and `AgentHeight` above it (default 5), and cuts out
  only what lies inside that band. A shelf whose underside is at 6 doesn't block, and one at
  3 does. It bakes in one height and throws the rest away.
- **The generalisation:**
  - **Core:** each obstacle polygon gets an optional **free height under it** (default 0, a
    normal full-height blocker, so existing levels don't change). Each triangle stores the
    lowest free height of the obstacles covering it.
  - **Adapter:** it slices each solid at the game's posture heights, for example 3 and 5, and
    emits:
    - the slice below 3 as a full blocker;
    - the slice between 3 and 5 as an obstacle leaving 3 studs free.
  - **Authoring:** still only obstacles. Nobody marks low ceilings.
- **Sloped ceilings:**
  - The slice's boundary at each height is exactly where the underside reaches that height.
    The adapter computes it from where the solid's edges cross that level, so a planar sloped
    underside is exact.
  - Between the listed heights it rounds to the safe side: a 4.2-stud NPC is treated as 5.
  - So the height list is a game setting, "the heights my NPCs use", like `MaxAgentRadius`.
    More levels mean finer slopes and more triangles.
- **Moving ceilings** (a lowering platform) need no new mechanism:
  - remove the platform's obstacles and add new ones from a runtime adapter helper,
    `NavMeshAdapter.ObstaclesFor(part, heights)`, then call `Update`;
  - that is ticket 22's local Update, a few ms per change;
  - ticket 28's helper says which NPCs' paths it touched;
  - how often a still-moving platform is reported (every few frames, or at the heights NPCs
    care about) is the game's choice, and so is crushing.
  - This also answers demo 2's pain point 6 ("dynamic Parts: footprint and floor by hand").
- **Rejected: slicing whole 3D solids in the core.** It would let `AddObstacle` take a solid
  without the adapter. But it moves 3D geometry into a core that is purely 2D today, for
  little gain.

## Still to decide when the ticket starts
- **Height list:** mesh-level (like `MaxAgentRadius`, fixed at Build), or adapter-only? It
  decides whether `AddObstacle` callers must pre-slice themselves.
- **Storage:** per-triangle free height, or obstacle free heights looked up at query time.
  Measure memory, bake size and query cost.
- **Format:** a v3 tagged section, either the obstacle field or a per-triangle field.
- **Clearance:** stays walls-only (SR4). A big agent can overhang a low region's edge, as at
  an excluded area's edge. Confirm and document.
- **Unsupported shapes:** non-convex Parts (unions, MeshParts) aren't supported by the adapter
  today. A ceiling made of them needs an upward-raycast sampling fallback. That's a later
  phase.
- **Specs needed:** the adapter specs cover yawed Parts and wedges, but not a pitched or rolled
  slab. Add one.

## Acceptance (draft; confirm when un-parking)
- [ ] An overhang fixture: a 5-stud NPC with no crouch goes around; with a crouch posture it
      goes under when the detour is long and around when it's short; a 2-stud NPC goes under
      at no extra cost.
- [ ] Posture-change waypoints at the exact boundaries, and follower events on crossing them.
- [ ] A sloped ceiling Part produces boundaries at each listed height, within the snap grid.
- [ ] A lowering platform (remove and re-add via `ObstaclesFor`, then `Update`) changes which
      NPCs can pass. "Update equals a fresh Build" holds.
- [ ] `FindRandomPoint` and the other queries respect the postures, as each does for excluded
      areas.
- [ ] Serialize round-trip; a bench of `FindPath` with and without postures; mutation at or
      above the baseline. Every spec has a negative control.
