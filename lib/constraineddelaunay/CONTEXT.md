# ConstrainedDelaunay: context

A 2D triangulation of points that is forced to contain given edges.

## Glossary

- **CDT** (constrained Delaunay triangulation): a triangulation of a point set that contains
  every constraint edge and is as Delaunay as those edges allow.
- **Constraint edge**: an input edge the triangulation must contain. It is directed, so its
  direction feeds the winding count.
- **Input edge**: one entry of the input's edge list, identified by its position. A
  constrained edge in the output records **every** input edge that covers it, because
  coincident constraints are common.
- **Steiner vertex**: a vertex the triangulation adds itself, at a constraint crossing or
  during Refine. Steiner vertices come after the input vertices.
- **Winding group**: an independent inside/outside count. A triangle's winding in group g is
  the net number of counter-clockwise group-g loops around it. Callers classify triangles by
  combining groups (e.g. walkable > 0 and obstacle == 0).
- **Hole**: not a separate concept. A hole is a clockwise loop in the same group, or a loop in
  its own group that the caller subtracts.
- **Refine**: adding Steiner vertices until triangle quality (minimum angle, maximum area)
  holds, or a Steiner budget runs out.
- **Plain state**: data with only string keys and dense arrays, no functions and no metatable,
  so it survives transfer between scripts and over the network unchanged.
