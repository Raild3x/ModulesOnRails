# 40: Riser seams (replace the adapter's ramp strips)

**What to build:** Let a seam join two floors whose heights differ along it by up to a maximum
step height, so a stair riser or a curb is one seam instead of the adapter's strip floor. Then
switch the Part adapter's step-height rule from strips to riser seams.

**Blocked by:** 34 (the strips and the building map to measure against). It touches Build and
Funnel, so schedule it beside a library track's turn on those files (E, F or W).

**Status:** needs-triage. Ruled 2026-10-01 (review.md, Track M1): "We will go with ramp strips
for now, but make a ticket for riser seams to replace it".

## Why
Ramp strips (ticket 34) double the floors and seams on a stair. On the building map:

| Join | Floors | Seams | Triangles | Build | Bake | Waypoints up the U-stair |
|---|---|---|---|---|---|---|
| Ramp strips (today) | 43 | 60 | 268 | 28 ms | 49.5 KB | 30 |
| Riser seams (core check loosened, prototype) | 13 | 30 | 160 | 16.5 ms | 29.8 KB | 19 |

Each strip also eats 0.25 studs off the lower tread.

## What the prototype showed
- The only check in the way is in `Build.joinSeam`: both portal ends must match in height to
  `HEIGHT_TOLERANCE`. Loosening that one comparison to 1.01 studs built the building, and
  every stair scenario passed at radius 0.5, 1 and 2. The narrow stair still refused radius 2.
- **Heights:** waypoints sit at the riser crossings, and the path's height is interpolated
  straight between them. So it slopes across each tread, up to 0.97 studs off the step tops
  (21-27% of samples more than 0.25 off, against 13-20% for strips). The drape (ticket 25) and
  `Advance` would need to know a riser seam is a step: hold the tread's height, then step at
  the riser.

## To do
- [ ] A seam may differ in height along it by up to a limit: per seam (`SeamDesc.MaxRise`?)
      or one `NavMeshDesc.MaxStepHeight`. Ask the user which. Keep a mismatch above the limit
      an authoring error.
- [ ] Funnel/drape: a riser seam's crossing keeps the tread's height up to the riser, then
      steps. Waypoints and `Advance` report the step.
- [ ] Clearance, Snap and IsPathValid across a riser seam: specs with negative controls.
- [ ] Serialize: whatever the seam stores (bump the format if needed).
- [ ] The Part adapter's `MaxStepHeight` emits riser seams instead of strips. The building
      map (`tools/navmesh/maps/Maps/Building.luau`) and M3's curbs must pass unchanged, with
      fewer floors.
- [ ] Re-measure the table above.
