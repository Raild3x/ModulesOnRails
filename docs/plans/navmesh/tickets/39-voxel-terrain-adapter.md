# 39: Roblox voxel Terrain adapter

**What to build:** Levels that use Roblox's voxel Terrain get a navmesh too. Terrain becomes
walkable floors with heights, and water becomes a non-walkable or weighted region, the same way
Parts do through the Part adapter.

**Blocked by:** 37 (uneven terrain built from Parts, the baseline to compare against)

**Status:** needs-triage. Ruled 2026-10-01: Parts first, voxel Terrain later.

- [ ] Read a Terrain region and produce walkable rings with heights. Walkable means a solid
      voxel with air above it, within a maximum slope.
- [ ] Turn water into either an obstacle or a weighted area, as a caller option.
- [ ] Rebuild ticket 37's forest and river with voxel Terrain plus Part trees and a Part
      bridge. Compare floors, triangles, Build ms, bake bytes and path quality against the
      Part version.
- [ ] Measure the triangle count Terrain's per-voxel height variation produces before and after
      the simplification passes (Track F). Present any needed resampling or smoothing as options
      to the user, with the numbers.
- [ ] Studio only (Terrain needs the engine). Specs run through the Studio test path, with
      screenshots.
