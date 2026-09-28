# 26: Authoring and debug ergonomics

**What to build:** Levels authored once, as Parts, and debug drawing that works for a real
scene.

**Blocked by:** none

**Status:** needs-triage (dogfood report, pain points 6, 12, 13 and 14)

- [ ] **A Part to `NavMeshDesc` adapter** for anchored blocks, wedges and cylinders.
  - It produces walkable floors, seams at ramp feet and tops, and the obstacle cut under a
    solid ramp.
  - Today the demo authors its level twice, and a ramp needs three hand-written pieces.
  - *(Added 2026-09-28, review.md D5 and D1.)*
    - **Area names:** the adapter maps each Part's `Material` (or an area attribute) to an
      integer area id, and returns a plain `{ [string]: number }` name-to-id table beside the
      description. Games write `AreaCosts = { [areas.Mud] = 4 }`. The core keeps integer ids.
    - **One-shot:** the adapter converts once. Watching Parts for moves is ruled out; games
      call `AddObstacle`/`Update` themselves.
    - **Headroom:** when ticket 29 lands, the adapter also emits `FloorDesc.Headroom` rings
      from the Parts above each floor.
- [ ] **Types say `vector`,** or a `Vector3 | vector` alias. The runtime already uses `vector`
      throughout, and strict-mode users under both Lune and Roblox currently hit type errors.
- [ ] **Silent mistakes get errors:**
  - `Walkable = ring` (a ring instead of a list of rings);
  - unknown `QueryFilter` keys (for example `AgentRaduis`);
  - optionally, a `HasPendingChanges(mesh)`.
- [ ] **Debug drawing:**
  - several paths in one draw list;
  - a palette option, since the default area grey and wall black vanish on grey or dark
    baseplates;
  - disabled links drawn differently;
  - tile bounds drawn at the floor's height;
  - `DrawListRenderer` reachable from `navmeshdebug`.
- [ ] **A documented recipe for shipping a bake** in a place (for example, base64 in a
      `StringValue`, with chunking), since a `\xNN` string literal is 4x the size.
- [ ] **Editor:**
  - a public way to place markers and set the radius from code (`EditorShot.luau` calls the
    private `_apply`);
  - a "build and save bake" action.
