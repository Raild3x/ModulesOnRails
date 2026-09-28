# 16: Floors, seams and links

**What to build:** Multi-floor navigation over seams and links, with path invalidation on toggles.

**Blocked by:** 14

**Status:** ready-for-agent

- [x] Seams on both floors, link labels, one-way links, toggles, `IsPathValid` stamps (SR5)
- [x] The three-floor fixture renders, with one floor at a time via layers (`tools/navmesh/scenes/floors`)

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Rulings (2026-09-27)
- **Seam joins: overlap portals** (user: "Lets go option A", after a pros/cons and prior-art
  comparison; this is how Detour stitches tiles).
  - Each floor snap-rounds its seam segment on its own.
  - Build pairs the seam's edge pieces on both floors by their overlap along the seam, and
    stores each overlap as a portal in one per-triangle extra-link table shared with links.
  - This amends SR3's "both floors of a seam share identical boundary vertices": the floors may
    differ by up to 1/256 stud along a seam.
  - "A seam not on both floors" is a Build error when a floor has no overlap for it.

## Built (2026-09-27)
- **Storage:** one extra-link list per triangle for seam portals and links; link records with
  an enabled flag; per-edge *open* flags (seam edges: no neighbour, not walls); tile stamps.
- **Build:**
  - Each seam is an open constraint in both floors' snap rounding, so it lines up with their
    triangle edges.
  - Pieces are then paired by overlap along the seam, with the triangles on opposite sides.
  - Link endpoints are snapped with the default extents.
  - Errors: a seam off a floor; floors that don't meet across a seam; different heights along
    it; a seam joining a floor to itself or of zero length; a link off the mesh; a bad cost or
    label.
- **Search:**
  - A seam portal crosses like an edge, and the corner and portal widths still apply.
  - A link walks to its start, pays cost x area multiplier, and lands at its end; disabled
    links and excluded areas are skipped.
  - SR7's heuristic scale includes the cheapest enabled link.
  - The corridor records how each triangle was entered.
- **Funnel:** seam portals are portals. A link breaks the string, and its label rides on the
  waypoint where it starts.
- **Public API:**
  - `FindPath` fills `TileStamps` with every corridor tile.
  - `IsPathValid` compares them.
  - `SetLinkEnabled` bumps both end tiles' stamps (SR5, conservative both ways).
  - `ToDrawList` has `Seams` and `Links` layers.
- **Fixtures:** `ThreeFloorStairs` (Ground runs on under the ramp), `LinkJump`, `OneWayLink`.
  The golden DrawLists were re-saved; the four earlier ones are byte-identical.
- **Known limits:**
  - Clearance near a seam counts only its own floor's walls.
  - Seam portal ends aren't offset for radius.
  - A link doesn't check agent radius.
  - Walls of every floor share the `Walls` layer.
