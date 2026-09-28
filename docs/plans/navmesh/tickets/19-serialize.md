# 19: Serialize and Deserialize

**What to build:** Meshes bake to versioned buffers and load back identically.

**Blocked by:** 18

**Status:** ready-for-agent

- [x] Layout-independent, versioned; a frozen v1 bake with its own snapshot; a version mismatch errors (SR9)

Spec: [../spec.md](../spec.md). Gates: the spec's "Gates for every ticket".

## Built (2026-09-27)
- **`Serialize.luau`:** format v1, magic "NVMS" plus a u16 version, written and read only
  through Storage accessors (SR9).
  - **Stored:** the radius cap; floors with their rebuild sources (tile size, areas, walkable
    rings); tiles with bounds, stamps and baseline triangulation inputs (R7); vertices with wall
    flags; triangles with neighbours, area, open edges, and corner/portal widths as f64; seams,
    seam pieces, links (enabled flag, label, one-way), and obstacle records.
  - **Rebuilt on load:** the derived extra links (seam portals and links), by Build's `connect`.
- **Errors:** another version, a foreign buffer, a truncated buffer, trailing bytes, and a
  non-buffer.
- **Frozen v1 bake:** `tools/navmesh/make_bake.luau` baked the three-floor fixture with an area
  on Upper, a one-way "Drop" link and a committed obstacle (3.7 KB, 4952 base64 characters).
  It lives in `NavMesh.Serialize.spec` with its own frozen DrawList snapshot, and was reviewed
  as a PNG.
- **Specs** (4):
  - every fixture round-trips byte for byte, and draws and paths the same;
  - a loaded mesh keeps its obstacles, stamps and toggles, and still updates identically to the
    original;
  - the frozen bake loads and matches its snapshot;
  - the load errors.
  - Negative controls, each failing the right tests: no link rebuild on load, and stamps not
    restored.
- **Also:** `Storage.SetTileStamp`, which `Tiles.luau` now uses in place of writing the field
  directly.
