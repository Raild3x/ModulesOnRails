--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMeshStorage
	@private

	The ONLY module that knows the mesh state's memory layout (ruling S1). Everything else goes
	through these accessors, so the layout can be swapped by replacing this file. The contract
	suite in `Tests/NavMesh.Storage.spec.luau` must pass. Inlined copies of these accessors, if
	any are ever made for speed, carry a `-- inlined: Storage.<fn>` tag: grep for it before
	changing the layout.

	**Layout (R4b):**
	- vertices are native `vector` values (X, height, Z), with f32 components;
	- i32 buffers hold the triangle vertices, the neighbours, and each triangle's floor, area and
	  tile;
	- plain arrays hold the floor names and the tile table.

	**Conventions:**
	- Triangles are CCW in the (X, Z) plane, i.e. `Orient2D(ax, az, bx, bz, cx, cz) > 0`.
	- Edge i is the edge opposite vertex i, and neighbour 0 means none.
	- Each tile owns one contiguous triangle range.

	**Clearance (ticket 15, SR4):** per triangle, three corner widths (between the two edges at
	vertex k) and three portal widths (across edge e), as f64 so exact widths compare exactly;
	one wall flag per vertex; and the optional `MaxAgentRadius` cap (0 = none, ruling U-a).

	**Extra links (ticket 16):** transitions beyond a triangle's three edges, in one list per
	triangle: seam portals to another floor (points a, b = the portal's left and right ends as
	seen crossing it) and links (a = where it starts, b = where it lands). Seam edges are flagged
	*open*: no neighbour, yet not a wall. Each tile has a stamp that `IsPathValid` compares.

	The state is plain data and passes `PlainData.Check`. Accessors arrive with the tickets that
	need them: obstacles and freeing slabs come later.
]=]

local I32 = 4
local F64 = 8
local TRI_SLOTS = 3
local MIN_CAPACITY = 16

export type State = {
	FloorNames: { string },
	VertexCount: number,
	Vertices: { vector },
	TriangleCount: number,
	TriangleCapacity: number,
	TriVerts: buffer, -- i32 x3 per triangle (CCW in X, Z)
	TriNeighbors: buffer, -- i32 x3 per triangle; across edge i (opposite vertex i); 0 = none
	TriFloor: buffer, -- i32 per triangle
	TriArea: buffer, -- i32 per triangle
	TriTile: buffer, -- i32 per triangle
	CornerWidths: buffer, -- f64 x3 per triangle: width between the two edges at vertex k
	PortalWidths: buffer, -- f64 x3 per triangle: width across edge e
	WallVertex: { boolean }, -- per vertex: on a wall edge
	MaxAgentRadius: number, -- 0 = uncapped
	TriOpenEdges: buffer, -- i32 per triangle: bit e-1 set when edge e is open (a seam edge)
	TriExtraHead: buffer, -- i32 per triangle: first extra link, 0 = none
	ExtraNext: { number },
	ExtraTarget: { number },
	ExtraKind: { number }, -- Storage.EXTRA_SEAM or Storage.EXTRA_LINK
	ExtraRef: { number }, -- links: the link id; seams: the slot of the seam edge in the source triangle
	ExtraA: { vector },
	ExtraB: { vector },
	LinkFromTri: { number },
	LinkToTri: { number },
	LinkFrom: { vector },
	LinkTo: { vector },
	LinkCost: { number },
	LinkArea: { number },
	LinkLabel: { string }, -- "" = none
	LinkBidirectional: { boolean },
	LinkEnabled: { boolean },
	TileFloor: { number },
	TileBounds: { number }, -- minX, minZ, maxX, maxZ per tile (studs)
	TileFirst: { number }, -- first triangle of the tile's range
	TileTriangles: { number }, -- triangle count of the tile's range
	TileStamp: { number },
}

local Storage = {}

Storage.EXTRA_SEAM = 1
Storage.EXTRA_LINK = 2

local function grown(old: buffer, usedBytes: number, newBytes: number): buffer
	local fresh = buffer.create(newBytes)
	buffer.copy(fresh, 0, old, 0, usedBytes)
	return fresh
end

local function ensureTriangles(s: State, needed: number)
	if needed <= s.TriangleCapacity then
		return
	end
	local capacity = s.TriangleCapacity
	while capacity < needed do
		capacity *= 2
	end
	local used = s.TriangleCount
	s.TriVerts = grown(s.TriVerts, used * TRI_SLOTS * I32, capacity * TRI_SLOTS * I32)
	s.TriNeighbors = grown(s.TriNeighbors, used * TRI_SLOTS * I32, capacity * TRI_SLOTS * I32)
	s.TriFloor = grown(s.TriFloor, used * I32, capacity * I32)
	s.TriArea = grown(s.TriArea, used * I32, capacity * I32)
	s.TriTile = grown(s.TriTile, used * I32, capacity * I32)
	s.CornerWidths = grown(s.CornerWidths, used * TRI_SLOTS * F64, capacity * TRI_SLOTS * F64)
	s.PortalWidths = grown(s.PortalWidths, used * TRI_SLOTS * F64, capacity * TRI_SLOTS * F64)
	s.TriOpenEdges = grown(s.TriOpenEdges, used * I32, capacity * I32)
	s.TriExtraHead = grown(s.TriExtraHead, used * I32, capacity * I32)
	s.TriangleCapacity = capacity
end

--[=[
	@within NavMeshStorage
	Creates an empty state.
]=]
function Storage.New(): State
	return {
		FloorNames = {},
		VertexCount = 0,
		Vertices = {},
		TriangleCount = 0,
		TriangleCapacity = MIN_CAPACITY,
		TriVerts = buffer.create(MIN_CAPACITY * TRI_SLOTS * I32),
		TriNeighbors = buffer.create(MIN_CAPACITY * TRI_SLOTS * I32),
		TriFloor = buffer.create(MIN_CAPACITY * I32),
		TriArea = buffer.create(MIN_CAPACITY * I32),
		TriTile = buffer.create(MIN_CAPACITY * I32),
		CornerWidths = buffer.create(MIN_CAPACITY * TRI_SLOTS * F64),
		PortalWidths = buffer.create(MIN_CAPACITY * TRI_SLOTS * F64),
		WallVertex = {},
		MaxAgentRadius = 0,
		TriOpenEdges = buffer.create(MIN_CAPACITY * I32),
		TriExtraHead = buffer.create(MIN_CAPACITY * I32),
		ExtraNext = {},
		ExtraTarget = {},
		ExtraKind = {},
		ExtraRef = {},
		ExtraA = {},
		ExtraB = {},
		LinkFromTri = {},
		LinkToTri = {},
		LinkFrom = {},
		LinkTo = {},
		LinkCost = {},
		LinkArea = {},
		LinkLabel = {},
		LinkBidirectional = {},
		LinkEnabled = {},
		TileFloor = {},
		TileBounds = {},
		TileFirst = {},
		TileTriangles = {},
		TileStamp = {},
	}
end

--[=[
	@within NavMeshStorage
	Pre-sizes storage for at least this many triangles (vertices live in a plain array).
]=]
function Storage.Reserve(s: State, triangleCount: number)
	ensureTriangles(s, triangleCount)
end

function Storage.VertexCount(s: State): number
	return s.VertexCount
end

function Storage.TriangleCount(s: State): number
	return s.TriangleCount
end

function Storage.TileCount(s: State): number
	return #s.TileFloor
end

function Storage.FloorCount(s: State): number
	return #s.FloorNames
end

--[=[
	@within NavMeshStorage
	Appends a vertex (X, height, Z in studs) and returns its id.
]=]
function Storage.AddVertex(s: State, position: vector): number
	local v = s.VertexCount + 1
	s.Vertices[v] = position
	s.WallVertex[v] = false
	s.VertexCount = v
	return v
end

function Storage.GetVertex(s: State, v: number): vector
	return s.Vertices[v]
end

function Storage.GetTriangle(s: State, t: number): (number, number, number)
	local o = (t - 1) * TRI_SLOTS * I32
	local b = s.TriVerts
	return buffer.readi32(b, o), buffer.readi32(b, o + I32), buffer.readi32(b, o + 2 * I32)
end

function Storage.SetTriangle(s: State, t: number, a: number, b: number, c: number)
	local o = (t - 1) * TRI_SLOTS * I32
	local buf = s.TriVerts
	buffer.writei32(buf, o, a)
	buffer.writei32(buf, o + I32, b)
	buffer.writei32(buf, o + 2 * I32, c)
end

--[=[
	@within NavMeshStorage
	The triangle across edge `e` (1..3, opposite vertex `e`) of `t`, or 0.
]=]
function Storage.GetNeighbor(s: State, t: number, e: number): number
	return buffer.readi32(s.TriNeighbors, ((t - 1) * TRI_SLOTS + e - 1) * I32)
end

function Storage.SetNeighbor(s: State, t: number, e: number, n: number)
	buffer.writei32(s.TriNeighbors, ((t - 1) * TRI_SLOTS + e - 1) * I32, n)
end

function Storage.GetTriangleFloor(s: State, t: number): number
	return buffer.readi32(s.TriFloor, (t - 1) * I32)
end

function Storage.SetTriangleFloor(s: State, t: number, floor: number)
	buffer.writei32(s.TriFloor, (t - 1) * I32, floor)
end

function Storage.GetTriangleArea(s: State, t: number): number
	return buffer.readi32(s.TriArea, (t - 1) * I32)
end

function Storage.SetTriangleArea(s: State, t: number, area: number)
	buffer.writei32(s.TriArea, (t - 1) * I32, area)
end

function Storage.GetTriangleTile(s: State, t: number): number
	return buffer.readi32(s.TriTile, (t - 1) * I32)
end

function Storage.SetTriangleTile(s: State, t: number, tile: number)
	buffer.writei32(s.TriTile, (t - 1) * I32, tile)
end

--[=[
	@within NavMeshStorage
	The width between the two edges of `t` at its vertex `k` (1..3): the widest agent that can
	pass from one to the other.
]=]
function Storage.GetCornerWidth(s: State, t: number, k: number): number
	return buffer.readf64(s.CornerWidths, ((t - 1) * TRI_SLOTS + k - 1) * F64)
end

function Storage.SetCornerWidth(s: State, t: number, k: number, width: number)
	buffer.writef64(s.CornerWidths, ((t - 1) * TRI_SLOTS + k - 1) * F64, width)
end

--[=[
	@within NavMeshStorage
	The width across edge `e` of `t`: the widest agent that can cross it.
]=]
function Storage.GetPortalWidth(s: State, t: number, e: number): number
	return buffer.readf64(s.PortalWidths, ((t - 1) * TRI_SLOTS + e - 1) * F64)
end

function Storage.SetPortalWidth(s: State, t: number, e: number, width: number)
	buffer.writef64(s.PortalWidths, ((t - 1) * TRI_SLOTS + e - 1) * F64, width)
end

function Storage.IsWallVertex(s: State, v: number): boolean
	return s.WallVertex[v]
end

function Storage.SetWallVertex(s: State, v: number, wall: boolean)
	s.WallVertex[v] = wall
end

--[=[
	@within NavMeshStorage
	The cap on agent radius the widths were built for; 0 = uncapped.
]=]
function Storage.GetMaxAgentRadius(s: State): number
	return s.MaxAgentRadius
end

function Storage.SetMaxAgentRadius(s: State, radius: number)
	s.MaxAgentRadius = radius
end

--[=[
	@within NavMeshStorage
	Registers a floor by name and returns its id.
]=]
function Storage.InsertFloor(s: State, name: string): number
	table.insert(s.FloorNames, name)
	return #s.FloorNames
end

function Storage.GetFloorName(s: State, floor: number): string
	return s.FloorNames[floor]
end

--[=[
	@within NavMeshStorage
	Registers a tile of `floor` with its bounds in studs, and an empty triangle range. Returns
	its id.
]=]
function Storage.InsertTile(s: State, floor: number, minX: number, minZ: number, maxX: number, maxZ: number): number
	table.insert(s.TileFloor, floor)
	table.insert(s.TileBounds, minX)
	table.insert(s.TileBounds, minZ)
	table.insert(s.TileBounds, maxX)
	table.insert(s.TileBounds, maxZ)
	table.insert(s.TileFirst, 0)
	table.insert(s.TileTriangles, 0)
	table.insert(s.TileStamp, 0)
	return #s.TileFloor
end

function Storage.GetTileFloor(s: State, tile: number): number
	return s.TileFloor[tile]
end

function Storage.GetTileBounds(s: State, tile: number): (number, number, number, number)
	local o = (tile - 1) * 4
	local b = s.TileBounds
	return b[o + 1], b[o + 2], b[o + 3], b[o + 4]
end

--[=[
	@within NavMeshStorage
	Gives `tile` a fresh range of `count` zeroed triangles, each tagged with the tile and its
	floor, and returns the first triangle id.
]=]
function Storage.AllocTileRange(s: State, tile: number, count: number): number
	-- ponytail: always appends. Freeing and reusing ranges arrives with Update (ticket 18).
	local first = s.TriangleCount + 1
	ensureTriangles(s, s.TriangleCount + count)
	s.TriangleCount += count
	local floor = s.TileFloor[tile]
	for t = first, first + count - 1 do
		Storage.SetTriangle(s, t, 0, 0, 0)
		for e = 1, 3 do
			Storage.SetNeighbor(s, t, e, 0)
		end
		Storage.SetTriangleFloor(s, t, floor)
		Storage.SetTriangleArea(s, t, 0)
		Storage.SetTriangleTile(s, t, tile)
		for k = 1, 3 do
			Storage.SetCornerWidth(s, t, k, 0)
			Storage.SetPortalWidth(s, t, k, 0)
		end
		buffer.writei32(s.TriOpenEdges, (t - 1) * I32, 0)
		buffer.writei32(s.TriExtraHead, (t - 1) * I32, 0)
	end
	s.TileFirst[tile] = first
	s.TileTriangles[tile] = count
	return first
end

--[=[
	@within NavMeshStorage
	The tile's triangle range: first id and count.
]=]
function Storage.GetTileRange(s: State, tile: number): (number, number)
	return s.TileFirst[tile], s.TileTriangles[tile]
end

--[=[
	@within NavMeshStorage
	Whether edge `e` of `t` is open: a seam edge, walkable although it has no neighbour.
]=]
function Storage.IsEdgeOpen(s: State, t: number, e: number): boolean
	return bit32.btest(buffer.readi32(s.TriOpenEdges, (t - 1) * I32), bit32.lshift(1, e - 1))
end

function Storage.SetEdgeOpen(s: State, t: number, e: number)
	local o = (t - 1) * I32
	buffer.writei32(s.TriOpenEdges, o, bit32.bor(buffer.readi32(s.TriOpenEdges, o), bit32.lshift(1, e - 1)))
end

--[=[
	@within NavMeshStorage
	Whether edge `e` of `t` is a wall: no neighbour, and not open.
]=]
function Storage.IsWallEdge(s: State, t: number, e: number): boolean
	return Storage.GetNeighbor(s, t, e) == 0 and not Storage.IsEdgeOpen(s, t, e)
end

--[=[
	@within NavMeshStorage
	Adds an extra link out of triangle `from` and returns its id. See the class docs for `a`, `b`.
]=]
function Storage.AddExtra(s: State, from: number, to: number, kind: number, ref: number, a: vector, b: vector): number
	local id = #s.ExtraNext + 1
	local o = (from - 1) * I32
	s.ExtraNext[id] = buffer.readi32(s.TriExtraHead, o)
	s.ExtraTarget[id] = to
	s.ExtraKind[id] = kind
	s.ExtraRef[id] = ref
	s.ExtraA[id] = a
	s.ExtraB[id] = b
	buffer.writei32(s.TriExtraHead, o, id)
	return id
end

--[=[
	@within NavMeshStorage
	The first extra link out of `t`, or 0.
]=]
function Storage.GetExtraHead(s: State, t: number): number
	return buffer.readi32(s.TriExtraHead, (t - 1) * I32)
end

--[=[
	@within NavMeshStorage
	Extra link `id`: (next id or 0, target triangle, kind, ref, a, b).
]=]
function Storage.GetExtra(s: State, id: number): (number, number, number, number, vector, vector)
	return s.ExtraNext[id], s.ExtraTarget[id], s.ExtraKind[id], s.ExtraRef[id], s.ExtraA[id], s.ExtraB[id]
end

function Storage.LinkCount(s: State): number
	return #s.LinkFromTri
end

--[=[
	@within NavMeshStorage
	Records a link (enabled) and returns its id. `label` "" means none.
]=]
function Storage.InsertLink(
	s: State,
	fromTri: number,
	from: vector,
	toTri: number,
	to: vector,
	cost: number,
	area: number,
	label: string,
	bidirectional: boolean
): number
	table.insert(s.LinkFromTri, fromTri)
	table.insert(s.LinkToTri, toTri)
	table.insert(s.LinkFrom, from)
	table.insert(s.LinkTo, to)
	table.insert(s.LinkCost, cost)
	table.insert(s.LinkArea, area)
	table.insert(s.LinkLabel, label)
	table.insert(s.LinkBidirectional, bidirectional)
	table.insert(s.LinkEnabled, true)
	return #s.LinkFromTri
end

--[=[
	@within NavMeshStorage
	Link `id`: (fromTri, from, toTri, to, cost, area, label, bidirectional, enabled).
]=]
function Storage.GetLink(
	s: State,
	id: number
): (number, vector, number, vector, number, number, string, boolean, boolean)
	return s.LinkFromTri[id],
		s.LinkFrom[id],
		s.LinkToTri[id],
		s.LinkTo[id],
		s.LinkCost[id],
		s.LinkArea[id],
		s.LinkLabel[id],
		s.LinkBidirectional[id],
		s.LinkEnabled[id]
end

function Storage.SetLinkFlag(s: State, id: number, enabled: boolean)
	s.LinkEnabled[id] = enabled
end

--[=[
	@within NavMeshStorage
	The tile's stamp: it changes whenever something a path through the tile depends on changes.
]=]
function Storage.GetTileStamp(s: State, tile: number): number
	return s.TileStamp[tile]
end

function Storage.BumpTileStamp(s: State, tile: number)
	s.TileStamp[tile] += 1
end

return Storage
