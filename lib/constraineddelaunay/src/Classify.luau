--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class Classify
	@private

	Per-group winding numbers (R3/SR1). A triangle's winding in group g is the net number of
	counter-clockwise group-g loops around it. Computed by a flood from a hull triangle (the
	outside has winding 0 in every group): crossing an edge into a triangle adds, for every
	covering input edge of group g, +1 when that input edge runs along the edge in the
	triangle's CCW direction and -1 when it runs against it. Group 0 contributes nothing.

	Winding is only well defined when every group >= 1 is balanced (closed loops): at every
	vertex, as many of the group's input edges leave as arrive. `Check` errors otherwise.
]=]

local Storage = require("./Storage")
local Types = require("./Types")

type State = Storage.State

-- Hot-path copies of the Storage accessors (bench.md, experiment 2: Triangulate 1.3-1.6x
-- faster). Local functions let the compiler inline them, and literal strides let it fold them
-- (reading them from Storage.Layout at runtime cost 7-19%). Each copy is tagged, and the load
-- check below fails loudly if Storage's layout ever changes without these copies.
local COORD_BYTES = 16
local I32 = 4
local TRI_BYTES = 12
assert(
	COORD_BYTES == Storage.Layout.COORD_BYTES
		and I32 == Storage.Layout.I32
		and TRI_BYTES == Storage.Layout.TRI_SLOTS * Storage.Layout.I32,
	"inlined Storage accessor copies are out of date with Storage.Layout"
)
-- inlined: Storage.GetTriangle
local function GetTriangle(s: State, t: number): (number, number, number)
	local o = (t - 1) * TRI_BYTES
	local b = s.TriVerts
	return buffer.readi32(b, o), buffer.readi32(b, o + I32), buffer.readi32(b, o + 2 * I32)
end
-- inlined: Storage.GetVertex
local function GetVertex(s: State, v: number): (number, number)
	local o = (v - 1) * COORD_BYTES
	return buffer.readf64(s.Coords, o), buffer.readf64(s.Coords, o + 8)
end
-- inlined: Storage.GetNeighbor
local function GetNeighbor(s: State, t: number, e: number): number
	return buffer.readi32(s.TriNeighbors, (t - 1) * TRI_BYTES + (e - 1) * I32)
end
-- inlined: Storage.GetWinding
local function GetWinding(s: State, t: number, group: number): number
	return buffer.readi32(s.Winding, ((t - 1) * (s.GroupCount + 1) + group) * I32)
end
-- inlined: Storage.SetWinding
local function SetWinding(s: State, t: number, group: number, value: number)
	buffer.writei32(s.Winding, ((t - 1) * (s.GroupCount + 1) + group) * I32, value)
end

local Classify = {}

local function groupOf(input: Types.TriangulateInput, k: number): number
	local groups = input.EdgeGroups
	if groups == nil then
		return 1
	end
	return groups[k] or 1
end

--[=[
	@within Classify
	Errors unless every group >= 1 forms closed loops (checked on merged vertices).
]=]
function Classify.CheckBalanced(s: State, input: Types.TriangulateInput)
	local edges = input.Edges or {}
	local balance: { [number]: { [number]: number } } = {}
	for k = 1, #edges // 2 do
		local group = groupOf(input, k)
		assert(group >= 0 and group % 1 == 0, "Triangulate: EdgeGroups must be non-negative integers")
		if group == 0 then
			continue
		end
		local u = Storage.VertexOfInput(s, edges[2 * k - 1])
		local v = Storage.VertexOfInput(s, edges[2 * k])
		if u == v then
			continue
		end
		local byVertex = balance[group] or {}
		balance[group] = byVertex
		byVertex[u] = (byVertex[u] or 0) + 1
		byVertex[v] = (byVertex[v] or 0) - 1
	end
	for group, byVertex in balance do
		for vertex, net in byVertex do
			if net ~= 0 then
				local input = Storage.InputVertexOf(s, vertex)
				error(
					`Triangulate: winding group {group} is not made of closed loops (input point {input} has {net} more outgoing than incoming edges). Use group 0 for open constraints.`,
					3
				)
			end
		end
	end
end

--[=[
	@within Classify
	Fills the winding of every triangle for groups 1..G. Call after the final triangulation
	(after `Compact`/`DropLeadingVertices`) and `Storage.AllocWinding`.
]=]
function Classify.Flood(s: State, input: Types.TriangulateInput)
	local groupCount = Storage.GroupCount(s)
	local triangleCount = Storage.TriangleCount(s)
	if groupCount == 0 or triangleCount == 0 then
		return
	end
	local coords = input.Coords
	local edges = input.Edges or {}

	-- Direction and group of each input edge (from the original input coordinates).
	local edgeGroup = table.create(#edges // 2, 0)
	local edgeDx = table.create(#edges // 2, 0)
	local edgeDy = table.create(#edges // 2, 0)
	for k = 1, #edges // 2 do
		local a, b = edges[2 * k - 1], edges[2 * k]
		edgeGroup[k] = groupOf(input, k)
		edgeDx[k] = coords[2 * b - 1] - coords[2 * a - 1]
		edgeDy[k] = coords[2 * b] - coords[2 * a]
	end

	-- delta(t, e, g): winding change crossing into t across its slot e, for group g.
	local delta = table.create(groupCount, 0)
	local function computeDelta(t: number, e: number)
		table.clear(delta)
		local count = Storage.GetCoveringEdgeCount(s, t, e)
		if count == 0 then
			return
		end
		local a, b, c = GetTriangle(s, t)
		local verts = { a, b, c }
		local ux, uy = GetVertex(s, verts[e % 3 + 1])
		local vx, vy = GetVertex(s, verts[(e + 1) % 3 + 1])
		for k = 1, count do
			local id = Storage.GetCoveringEdge(s, t, e, k)
			local group = edgeGroup[id]
			if group > 0 then
				local along = (vx - ux) * edgeDx[id] + (vy - uy) * edgeDy[id]
				delta[group] = (delta[group] or 0) + (if along > 0 then 1 else -1)
			end
		end
	end

	-- Seed: a triangle on the hull, entered from the outside (winding 0).
	local seed, seedSlot = 0, 0
	for t = 1, triangleCount do
		for e = 1, 3 do
			if GetNeighbor(s, t, e) == 0 then
				seed, seedSlot = t, e
				break
			end
		end
		if seed ~= 0 then
			break
		end
	end
	computeDelta(seed, seedSlot)
	for g = 1, groupCount do
		SetWinding(s, seed, g, delta[g] or 0)
	end

	local visited = table.create(triangleCount, false)
	visited[seed] = true
	local queue = { seed }
	local head = 1
	while head <= #queue do
		local t = queue[head]
		head += 1
		for e = 1, 3 do
			local n = GetNeighbor(s, t, e)
			if n == 0 or visited[n] then
				continue
			end
			visited[n] = true
			computeDelta(t, e)
			for g = 1, groupCount do
				-- Leaving t across e is the reverse of entering t across e.
				SetWinding(s, n, g, GetWinding(s, t, g) - (delta[g] or 0))
			end
			table.insert(queue, n)
		end
	end
end

return Classify
