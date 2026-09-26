--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class CDTStorage
	@private

	The ONLY module that knows the Triangulation's memory layout (ruling S1). Everything else,
	including the public read functions, goes through these accessors, so the layout can be
	swapped by replacing this file (the contract suite in `Tests/CDT.Storage.spec.luau`
	must pass). Inlined copies of these accessors, if any are ever made for speed, carry a
	`-- inlined: Storage.<fn>` tag: grep for it before changing the layout.

	Layout (R4a/R4b): f64 coordinate buffer (x, y per vertex); i32 buffers for triangle
	vertices, neighbours, constraint-coverage heads, the input/vertex maps and winding.
	Constraint coverage is a linked-list node pool (head per triangle edge) so coverage can
	move between edges during construction; readers see only Count/Get.
	The state is plain data (buffers and numbers) and passes `PlainData.Check`.
]=]

local COORD_BYTES = 16 -- two f64 per vertex
local I32 = 4
local TRI_SLOTS = 3
local MIN_CAPACITY = 16

export type State = {
	-- vertices
	VertexCount: number,
	VertexCapacity: number,
	Coords: buffer,
	InputOfVertex: buffer, -- i32 per vertex: first input point merged into it, 0 = Steiner
	-- input points
	InputCount: number,
	VertexOfInput: buffer, -- i32 per input point
	-- triangles
	TriangleCount: number,
	TriangleCapacity: number,
	TriVerts: buffer, -- i32 x3 per triangle (CCW)
	TriNeighbors: buffer, -- i32 x3 per triangle; neighbour across edge i (opposite vertex i); 0 = none
	CoverHeads: buffer, -- i32 x3 per triangle; head of that edge's covering-edge list, 0 = unconstrained
	-- covering-edge node pool (linked lists)
	CoverCount: number,
	CoverCapacity: number,
	CoverNext: buffer, -- i32 per node
	CoverEdge: buffer, -- i32 per node: input-edge id
	-- winding
	GroupCount: number,
	Winding: buffer, -- i32 x (GroupCount + 1) per triangle; allocated by AllocWinding
}

local Storage = {}

--[=[
	@within CDTStorage
	The layout constants that inlined accessor copies must read (never literals), so a layout
	change and its `-- inlined: Storage.<fn>` copies move together.
]=]
Storage.Layout = table.freeze {
	COORD_BYTES = COORD_BYTES, -- per vertex: x then y, f64
	I32 = I32, -- bytes per slot of the triangle, neighbour, cover-head and winding buffers
	TRI_SLOTS = TRI_SLOTS, -- slots per triangle
}

local function grown(old: buffer, usedBytes: number, newBytes: number): buffer
	local fresh = buffer.create(newBytes)
	buffer.copy(fresh, 0, old, 0, usedBytes)
	return fresh
end

--[=[
	@within CDTStorage
	Creates an empty state for `inputCount` input points and winding groups `0..groupCount`.
]=]
function Storage.New(inputCount: number, groupCount: number): State
	return {
		VertexCount = 0,
		VertexCapacity = MIN_CAPACITY,
		Coords = buffer.create(MIN_CAPACITY * COORD_BYTES),
		InputOfVertex = buffer.create(MIN_CAPACITY * I32),
		InputCount = inputCount,
		VertexOfInput = buffer.create(math.max(inputCount, 1) * I32),
		TriangleCount = 0,
		TriangleCapacity = MIN_CAPACITY,
		TriVerts = buffer.create(MIN_CAPACITY * TRI_SLOTS * I32),
		TriNeighbors = buffer.create(MIN_CAPACITY * TRI_SLOTS * I32),
		CoverHeads = buffer.create(MIN_CAPACITY * TRI_SLOTS * I32),
		CoverCount = 0,
		CoverCapacity = MIN_CAPACITY,
		CoverNext = buffer.create(MIN_CAPACITY * I32),
		CoverEdge = buffer.create(MIN_CAPACITY * I32),
		GroupCount = groupCount,
		Winding = buffer.create(0),
	}
end

local function reserveVertices(s: State, count: number)
	if count <= s.VertexCapacity then
		return
	end
	local capacity = math.max(count, s.VertexCapacity * 2)
	s.Coords = grown(s.Coords, s.VertexCount * COORD_BYTES, capacity * COORD_BYTES)
	s.InputOfVertex = grown(s.InputOfVertex, s.VertexCount * I32, capacity * I32)
	s.VertexCapacity = capacity
end

local function reserveTriangles(s: State, count: number)
	if count <= s.TriangleCapacity then
		return
	end
	local capacity = math.max(count, s.TriangleCapacity * 2)
	local used = s.TriangleCount * TRI_SLOTS * I32
	local bytes = capacity * TRI_SLOTS * I32
	s.TriVerts = grown(s.TriVerts, used, bytes)
	s.TriNeighbors = grown(s.TriNeighbors, used, bytes)
	s.CoverHeads = grown(s.CoverHeads, used, bytes)
	s.TriangleCapacity = capacity
end

--[=[
	@within CDTStorage
	Pre-sizes storage for at least `vertices` vertices and `triangles` triangles.
]=]
function Storage.Reserve(s: State, vertices: number, triangles: number)
	reserveVertices(s, vertices)
	reserveTriangles(s, triangles)
end

function Storage.VertexCount(s: State): number
	return s.VertexCount
end

function Storage.TriangleCount(s: State): number
	return s.TriangleCount
end

function Storage.GroupCount(s: State): number
	return s.GroupCount
end

function Storage.InputCount(s: State): number
	return s.InputCount
end

--[=[
	@within CDTStorage
	Appends a vertex and returns its id.
]=]
function Storage.AddVertex(s: State, x: number, y: number): number
	local v = s.VertexCount + 1
	reserveVertices(s, v)
	local offset = (v - 1) * COORD_BYTES
	buffer.writef64(s.Coords, offset, x)
	buffer.writef64(s.Coords, offset + 8, y)
	buffer.writei32(s.InputOfVertex, (v - 1) * I32, 0)
	s.VertexCount = v
	return v
end

function Storage.GetVertex(s: State, v: number): (number, number)
	local offset = (v - 1) * COORD_BYTES
	return buffer.readf64(s.Coords, offset), buffer.readf64(s.Coords, offset + 8)
end

--[=[
	@within CDTStorage
	Records that input point `input` became vertex `vertex`. The first input point mapped to a
	vertex is the one `InputVertexOf` reports (duplicates merge into it).
]=]
function Storage.SetInputVertex(s: State, input: number, vertex: number)
	buffer.writei32(s.VertexOfInput, (input - 1) * I32, vertex)
	local offset = (vertex - 1) * I32
	if buffer.readi32(s.InputOfVertex, offset) == 0 then
		buffer.writei32(s.InputOfVertex, offset, input)
	end
end

function Storage.InputVertexOf(s: State, vertex: number): number?
	local input = buffer.readi32(s.InputOfVertex, (vertex - 1) * I32)
	if input == 0 then
		return nil
	end
	return input
end

function Storage.VertexOfInput(s: State, input: number): number
	return buffer.readi32(s.VertexOfInput, (input - 1) * I32)
end

--[=[
	@within CDTStorage
	Appends a triangle (CCW vertex ids) with no neighbours and no coverage; returns its id.
]=]
function Storage.AddTriangle(s: State, a: number, b: number, c: number): number
	local t = s.TriangleCount + 1
	reserveTriangles(s, t)
	local offset = (t - 1) * TRI_SLOTS * I32
	buffer.writei32(s.TriVerts, offset, a)
	buffer.writei32(s.TriVerts, offset + I32, b)
	buffer.writei32(s.TriVerts, offset + 2 * I32, c)
	for slot = 0, TRI_SLOTS - 1 do
		buffer.writei32(s.TriNeighbors, offset + slot * I32, 0)
		buffer.writei32(s.CoverHeads, offset + slot * I32, 0)
	end
	s.TriangleCount = t
	return t
end

function Storage.GetTriangle(s: State, t: number): (number, number, number)
	local offset = (t - 1) * TRI_SLOTS * I32
	return buffer.readi32(s.TriVerts, offset),
		buffer.readi32(s.TriVerts, offset + I32),
		buffer.readi32(s.TriVerts, offset + 2 * I32)
end

function Storage.SetTriangle(s: State, t: number, a: number, b: number, c: number)
	local offset = (t - 1) * TRI_SLOTS * I32
	buffer.writei32(s.TriVerts, offset, a)
	buffer.writei32(s.TriVerts, offset + I32, b)
	buffer.writei32(s.TriVerts, offset + 2 * I32, c)
end

--[=[
	@within CDTStorage
	Neighbour of triangle `t` across edge `e` (1..3, opposite vertex `e`); 0 = none.
]=]
function Storage.GetNeighbor(s: State, t: number, e: number): number
	return buffer.readi32(s.TriNeighbors, ((t - 1) * TRI_SLOTS + e - 1) * I32)
end

function Storage.SetNeighbor(s: State, t: number, e: number, n: number)
	buffer.writei32(s.TriNeighbors, ((t - 1) * TRI_SLOTS + e - 1) * I32, n)
end

function Storage.GetCoverHead(s: State, t: number, e: number): number
	return buffer.readi32(s.CoverHeads, ((t - 1) * TRI_SLOTS + e - 1) * I32)
end

function Storage.SetCoverHead(s: State, t: number, e: number, head: number)
	buffer.writei32(s.CoverHeads, ((t - 1) * TRI_SLOTS + e - 1) * I32, head)
end

--[=[
	@within CDTStorage
	Allocates a covering-edge node holding `inputEdge` in front of list `head`; returns the
	new head. Lists are shared by value: set it on both sides of the edge.
]=]
function Storage.PushCover(s: State, head: number, inputEdge: number): number
	local node = s.CoverCount + 1
	if node > s.CoverCapacity then
		local capacity = s.CoverCapacity * 2
		s.CoverNext = grown(s.CoverNext, s.CoverCount * I32, capacity * I32)
		s.CoverEdge = grown(s.CoverEdge, s.CoverCount * I32, capacity * I32)
		s.CoverCapacity = capacity
	end
	buffer.writei32(s.CoverNext, (node - 1) * I32, head)
	buffer.writei32(s.CoverEdge, (node - 1) * I32, inputEdge)
	s.CoverCount = node
	return node
end

--[=[
	@within CDTStorage
	Number of input edges covering edge `e` of triangle `t` (0 = unconstrained).
]=]
function Storage.GetCoveringEdgeCount(s: State, t: number, e: number): number
	local count = 0
	local node = Storage.GetCoverHead(s, t, e)
	while node ~= 0 do
		count += 1
		node = buffer.readi32(s.CoverNext, (node - 1) * I32)
	end
	return count
end

--[=[
	@within CDTStorage
	The `k`-th (1-based) input-edge id covering edge `e` of triangle `t`.
]=]
function Storage.GetCoveringEdge(s: State, t: number, e: number, k: number): number
	local node = Storage.GetCoverHead(s, t, e)
	for _ = 2, k do
		node = buffer.readi32(s.CoverNext, (node - 1) * I32)
	end
	assert(node ~= 0, "covering edge index out of range")
	return buffer.readi32(s.CoverEdge, (node - 1) * I32)
end

--[=[
	@within CDTStorage
	Allocates zeroed winding storage for the current triangles (call once they are final).
]=]
function Storage.AllocWinding(s: State)
	s.Winding = buffer.create(math.max(s.TriangleCount, 1) * (s.GroupCount + 1) * I32)
end

function Storage.GetWinding(s: State, t: number, group: number): number
	return buffer.readi32(s.Winding, ((t - 1) * (s.GroupCount + 1) + group) * I32)
end

function Storage.SetWinding(s: State, t: number, group: number, value: number)
	buffer.writei32(s.Winding, ((t - 1) * (s.GroupCount + 1) + group) * I32, value)
end

--[=[
	@within CDTStorage
	Keeps only triangles with `keep[t] == true`, renumbering them densely in order.
	Neighbour references to dropped triangles become 0. Call before `AllocWinding`.
]=]
function Storage.Compact(s: State, keep: { boolean })
	local newId = table.create(s.TriangleCount, 0)
	local count = 0
	for t = 1, s.TriangleCount do
		if keep[t] then
			count += 1
			newId[t] = count
		end
	end
	for t = 1, s.TriangleCount do
		local target = newId[t]
		if target == 0 then
			continue
		end
		local from = (t - 1) * TRI_SLOTS * I32
		local to = (target - 1) * TRI_SLOTS * I32
		for slot = 0, TRI_SLOTS - 1 do
			buffer.writei32(s.TriVerts, to + slot * I32, buffer.readi32(s.TriVerts, from + slot * I32))
			buffer.writei32(s.CoverHeads, to + slot * I32, buffer.readi32(s.CoverHeads, from + slot * I32))
			local n = buffer.readi32(s.TriNeighbors, from + slot * I32)
			buffer.writei32(s.TriNeighbors, to + slot * I32, if n == 0 then 0 else newId[n])
		end
	end
	s.TriangleCount = count
end

--[=[
	@within CDTStorage
	Removes vertices `1..n` (which no triangle may reference) and shifts every other vertex
	id down by `n`, fixing triangles and the input/vertex maps.
]=]
function Storage.DropLeadingVertices(s: State, n: number)
	local remaining = s.VertexCount - n
	buffer.copy(s.Coords, 0, s.Coords, n * COORD_BYTES, remaining * COORD_BYTES)
	buffer.copy(s.InputOfVertex, 0, s.InputOfVertex, n * I32, remaining * I32)
	s.VertexCount = remaining
	for i = 0, s.TriangleCount * TRI_SLOTS - 1 do
		local v = buffer.readi32(s.TriVerts, i * I32)
		assert(v > n, "DropLeadingVertices: a triangle still references a dropped vertex")
		buffer.writei32(s.TriVerts, i * I32, v - n)
	end
	for input = 1, s.InputCount do
		local offset = (input - 1) * I32
		local v = buffer.readi32(s.VertexOfInput, offset)
		if v > 0 then
			buffer.writei32(s.VertexOfInput, offset, v - n)
		end
	end
end

return Storage
