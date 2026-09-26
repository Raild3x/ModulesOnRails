--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Test-only invariant checker for triangulations (test layer 1). Reads only the public API.
-- Returns (true) or (false, message describing the first violation).

local CDT = require("../../ConstrainedDelaunay")

type Triangulation = CDT.Triangulation

local Invariants = {}

local function edgeVertices(tri: Triangulation, t: number, e: number): (number, number)
	local a, b, c = CDT.GetTriangle(tri, t)
	local verts = { a, b, c }
	return verts[e % 3 + 1], verts[(e + 1) % 3 + 1]
end

--[=[
	Checks (a) CCW + neighbour symmetry, (c) local constrained Delaunay, the convex hull,
	Euler's count, input mapping and plain data. `coords` is the TriangulateInput.Coords.
]=]
function Invariants.Check(tri: Triangulation, coords: { number }, edges: { number }?): (boolean, string?)
	local triangleCount = CDT.TriangleCount(tri)
	local vertexCount = CDT.VertexCount(tri)
	local boundaryEdges = {}

	for t = 1, triangleCount do
		local a, b, c = CDT.GetTriangle(tri, t)
		local ax, ay = CDT.GetVertex(tri, a)
		local bx, by = CDT.GetVertex(tri, b)
		local cx, cy = CDT.GetVertex(tri, c)
		if CDT.Orient2D(ax, ay, bx, by, cx, cy) <= 0 then
			return false, `triangle {t} ({a},{b},{c}) is not strictly counter-clockwise`
		end
		for e = 1, 3 do
			local u, v = edgeVertices(tri, t, e)
			local n = CDT.GetNeighbor(tri, t, e)
			if n == 0 then
				table.insert(boundaryEdges, { u, v })
				continue
			end
			local back = 0
			for j = 1, 3 do
				if CDT.GetNeighbor(tri, n, j) == t then
					back = j
				end
			end
			if back == 0 then
				return false, `neighbour {n} of triangle {t} does not link back`
			end
			local nu, nv = edgeVertices(tri, n, back)
			if nu ~= v or nv ~= u then
				return false, `triangles {t} and {n} disagree on their shared edge`
			end
			if CDT.GetCoveringEdgeCount(tri, t, e) == 0 then
				local nverts = { CDT.GetTriangle(tri, n) }
				local q = nverts[back]
				local qx, qy = CDT.GetVertex(tri, q)
				if CDT.InCircle(ax, ay, bx, by, cx, cy, qx, qy) > 0 then
					return false, `edge ({u},{v}) between triangles {t} and {n} is not locally Delaunay`
				end
			end
		end
	end

	-- Convex hull: every vertex lies left of (or on) every boundary edge.
	for _, edge in boundaryEdges do
		local ux, uy = CDT.GetVertex(tri, edge[1])
		local vx, vy = CDT.GetVertex(tri, edge[2])
		for w = 1, vertexCount do
			local wx, wy = CDT.GetVertex(tri, w)
			if CDT.Orient2D(ux, uy, vx, vy, wx, wy) < 0 then
				return false, `vertex {w} lies outside boundary edge ({edge[1]},{edge[2]}): hull not convex`
			end
		end
	end

	-- Euler for a triangulated convex hull with H boundary edges: T = 2V - 2 - H.
	if triangleCount > 0 and triangleCount ~= 2 * vertexCount - 2 - #boundaryEdges then
		return false, `Euler count failed: T={triangleCount}, V={vertexCount}, H={#boundaryEdges}`
	end

	-- Every input point maps to a vertex with identical coordinates.
	for i = 1, #coords // 2 do
		local v = CDT.VertexOfInput(tri, i)
		if v < 1 or v > vertexCount then
			return false, `input point {i} maps to no vertex`
		end
		local x, y = CDT.GetVertex(tri, v)
		if x ~= coords[2 * i - 1] or y ~= coords[2 * i] then
			return false, `input point {i} moved`
		end
	end

	-- (b) Every input constraint is a chain of edges covered by its id, endpoint to endpoint.
	if edges and #edges > 0 then
		local adjacency: { [number]: { [number]: { number } } } = {}
		for t = 1, triangleCount do
			for e = 1, 3 do
				for k = 1, CDT.GetCoveringEdgeCount(tri, t, e) do
					local id = CDT.GetCoveringEdge(tri, t, e, k)
					local u, v = edgeVertices(tri, t, e)
					local byVertex = adjacency[id] or {}
					adjacency[id] = byVertex
					byVertex[u] = byVertex[u] or {}
					byVertex[v] = byVertex[v] or {}
					table.insert(byVertex[u], v)
					table.insert(byVertex[v], u)
				end
			end
		end
		for k = 1, #edges // 2 do
			local from = CDT.VertexOfInput(tri, edges[2 * k - 1])
			local to = CDT.VertexOfInput(tri, edges[2 * k])
			if from == to then
				continue
			end
			local byVertex = adjacency[k] or {}
			local seen = { [from] = true }
			local frontier = { from }
			while #frontier > 0 do
				local current = table.remove(frontier) :: number
				for _, nextVertex in byVertex[current] or {} do
					if not seen[nextVertex] then
						seen[nextVertex] = true
						table.insert(frontier, nextVertex)
					end
				end
			end
			if not seen[to] then
				return false, `constraint {k} (vertex {from} -> {to}) is not a covered chain`
			end
		end
	end

	local plain, reason = CDT.PlainData.Check(tri)
	if not plain then
		return false, `state is not plain data: {reason}`
	end
	return true, nil
end

return Invariants
