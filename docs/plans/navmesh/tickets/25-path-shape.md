# 25: Path shape and waypoint metadata

**What to build:** Waypoints that a tween or `Humanoid:MoveTo` can follow directly, and links
that are addressable by name.

**Blocked by:** none

**Status:** needs-triage (dogfood report, pain points 8, 9 and 15; repros 4 and 7)

- [ ] **Waypoints where a path crosses a seam or a crease (slope change).**
  - Today a ramp-to-balcony path has no point at the ramp's top. Interpolating Y between
    waypoints passes 3 studs under the surface, and `FindNearestPoint` then lands on the floor
    below (repro 7).
  - The alternative is a `SamplePath(path, spacing)` helper.
- [ ] **Equal-cost area boundaries don't bend paths.**
  - Repro 4: a patch with cost 1 makes a path 8% longer.
  - Candidate fix: a final shortcut pass over segments whose area costs are equal.
- [ ] **Link id on the link's waypoint.**
- [ ] **An optional `Name` on `LinkDesc`,** with `SetLinkEnabled` accepting it, since today
      it only takes an index into `Links`.
- [ ] Decide whether `PathResult` gains a `Length` (the 3D polyline length). `Cost` is the
      search cost and differs from it.

The corner-chord clearance is documented in `QueryFilter.AgentRadius` as of 3ce0e7c. Emitting
an arc-midpoint waypoint on sharp turns stays optional.
