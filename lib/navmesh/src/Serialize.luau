--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshSerialize
	@private

	The versioned byte format for baked meshes (SR9, P3). It is written and read through Storage
	accessors only, so it is independent of the in-memory layout: swapping `Storage.luau` never
	changes old bakes.

	**Layout (v1):** "NVMS", a u16 version, then in order:
	- the radius cap (f64);
	- floors: name, tile size, default area, area ids, walkable rings (grid X/Z as i32, heights
	  as f64);
	- tiles: floor, bounds (f64), stamp, rebuild sources;
	- vertices (f32 X/Y/Z, as stored, plus the wall flag);
	- per tile, its triangles: vertices, neighbours, area, open edges, corner and portal widths
	  (f64);
	- seams, seam pieces, links, and obstacle records.
	Extra links (seam portals and links) are derived data: `Deserialize` rebuilds them exactly
	as Build does.

	A buffer of another version errors on `Deserialize`; a v2 format adds a v2 reader and a v2
	bake, and the v1 bake is then expected to error (SR9).
]=]

local Build = require("./Build")
local Storage = require("./Storage")

type State = Storage.State

local MAGIC = "NVMS"
local VERSION = 1

local Serialize = {}

-- A growing byte writer.
type Writer = { Buffer: buffer, Size: number }

local function reserve(w: Writer, bytes: number)
	local needed = w.Size + bytes
	local capacity = buffer.len(w.Buffer)
	if needed > capacity then
		while capacity < needed do
			capacity *= 2
		end
		local grown = buffer.create(capacity)
		buffer.copy(grown, 0, w.Buffer, 0, w.Size)
		w.Buffer = grown
	end
end

local function u8(w: Writer, v: number)
	reserve(w, 1)
	buffer.writeu8(w.Buffer, w.Size, v)
	w.Size += 1
end

local function u16(w: Writer, v: number)
	reserve(w, 2)
	buffer.writeu16(w.Buffer, w.Size, v)
	w.Size += 2
end

local function u32(w: Writer, v: number)
	reserve(w, 4)
	buffer.writeu32(w.Buffer, w.Size, v)
	w.Size += 4
end

local function i32(w: Writer, v: number)
	reserve(w, 4)
	buffer.writei32(w.Buffer, w.Size, v)
	w.Size += 4
end

local function f32(w: Writer, v: number)
	reserve(w, 4)
	buffer.writef32(w.Buffer, w.Size, v)
	w.Size += 4
end

local function f64(w: Writer, v: number)
	reserve(w, 8)
	buffer.writef64(w.Buffer, w.Size, v)
	w.Size += 8
end

local function str(w: Writer, v: string)
	u16(w, #v)
	reserve(w, #v)
	buffer.writestring(w.Buffer, w.Size, v)
	w.Size += #v
end

local function vec(w: Writer, v: vector)
	f32(w, v.X)
	f32(w, v.Y)
	f32(w, v.Z)
end

local function list(w: Writer, values: { number }, write: (Writer, number) -> ())
	u32(w, #values)
	for _, v in values do
		write(w, v)
	end
end

--[=[
	@within NavMeshSerialize
	The mesh as a versioned buffer.
]=]
function Serialize.Serialize(s: State): buffer
	local w: Writer = { Buffer = buffer.create(1024), Size = 0 }
	reserve(w, 4)
	buffer.writestring(w.Buffer, 0, MAGIC)
	w.Size = 4
	u16(w, VERSION)
	f64(w, Storage.GetMaxAgentRadius(s))

	u32(w, Storage.FloorCount(s))
	for f = 1, Storage.FloorCount(s) do
		str(w, Storage.GetFloorName(s, f))
		local tileSize, defaultArea, areaIds, rings = Storage.GetFloorSources(s, f)
		f64(w, tileSize)
		u32(w, defaultArea)
		list(w, areaIds, u32)
		u32(w, #rings)
		for _, ring in rings do
			list(w, ring.X, i32)
			list(w, ring.Z, i32)
			list(w, ring.Y, f64)
		end
	end

	u32(w, Storage.TileCount(s))
	for tile = 1, Storage.TileCount(s) do
		u32(w, Storage.GetTileFloor(s, tile))
		for _, b in { Storage.GetTileBounds(s, tile) } do
			f64(w, b)
		end
		u32(w, Storage.GetTileStamp(s, tile))
		local tc, te, tg, ts = Storage.GetTileSources(s, tile)
		list(w, tc, i32)
		list(w, te, u32)
		list(w, tg, u32)
		list(w, ts, u32)
	end

	u32(w, Storage.VertexCount(s))
	for v = 1, Storage.VertexCount(s) do
		vec(w, Storage.GetVertex(s, v))
		u8(w, if Storage.IsWallVertex(s, v) then 1 else 0)
	end

	for tile = 1, Storage.TileCount(s) do
		local first, count = Storage.GetTileRange(s, tile)
		u32(w, count)
		for t = first, first + count - 1 do
			for _, v in { Storage.GetTriangle(s, t) } do
				u32(w, v)
			end
			for e = 1, 3 do
				u32(w, Storage.GetNeighbor(s, t, e))
			end
			u32(w, Storage.GetTriangleArea(s, t))
			local open = 0
			for e = 1, 3 do
				if Storage.IsEdgeOpen(s, t, e) then
					open += bit32.lshift(1, e - 1)
				end
			end
			u8(w, open)
			for k = 1, 3 do
				f64(w, Storage.GetCornerWidth(s, t, k))
				f64(w, Storage.GetPortalWidth(s, t, k))
			end
		end
	end

	u32(w, Storage.SeamCount(s))
	for seam = 1, Storage.SeamCount(s) do
		local a, b, ax, az, bx, bz = Storage.GetSeam(s, seam)
		u32(w, a)
		u32(w, b)
		for _, v in { ax, az, bx, bz } do
			i32(w, v)
		end
	end
	u32(w, Storage.PieceCount(s))
	for piece = 1, Storage.PieceCount(s) do
		local seam, tri, edge = Storage.GetPiece(s, piece)
		u32(w, seam)
		u32(w, tri)
		u8(w, edge)
	end

	u32(w, Storage.LinkCount(s))
	for id = 1, Storage.LinkCount(s) do
		local fromTri, from, toTri, to, cost, area, label, both, enabled = Storage.GetLink(s, id)
		u32(w, fromTri)
		vec(w, from)
		u32(w, toTri)
		vec(w, to)
		f64(w, cost)
		u32(w, area)
		str(w, label)
		u8(w, (if both then 1 else 0) + (if enabled then 2 else 0))
	end

	u32(w, Storage.ObstacleCount(s))
	for id = 1, Storage.ObstacleCount(s) do
		local floor, state, xs, zs = Storage.GetObstacleRecord(s, id)
		u32(w, floor)
		u8(w, state)
		list(w, xs, i32)
		list(w, zs, i32)
	end

	local out = buffer.create(w.Size)
	buffer.copy(out, 0, w.Buffer, 0, w.Size)
	return out
end

-- A byte reader over a buffer.
type Reader = { Buffer: buffer, At: number }

local function take(r: Reader, bytes: number): number
	local at = r.At
	if at + bytes > buffer.len(r.Buffer) then
		error("NavMesh.Deserialize: the buffer is truncated or corrupt", 0)
	end
	r.At = at + bytes
	return at
end

local function ru8(r: Reader): number
	return buffer.readu8(r.Buffer, take(r, 1))
end

local function ru16(r: Reader): number
	return buffer.readu16(r.Buffer, take(r, 2))
end

local function ru32(r: Reader): number
	return buffer.readu32(r.Buffer, take(r, 4))
end

local function ri32(r: Reader): number
	return buffer.readi32(r.Buffer, take(r, 4))
end

local function rf32(r: Reader): number
	return buffer.readf32(r.Buffer, take(r, 4))
end

local function rf64(r: Reader): number
	return buffer.readf64(r.Buffer, take(r, 8))
end

local function rstr(r: Reader): string
	local n = ru16(r)
	return buffer.readstring(r.Buffer, take(r, n), n)
end

local function rvec(r: Reader): vector
	local x, y, z = rf32(r), rf32(r), rf32(r)
	return vector.create(x, y, z)
end

local function rlist(r: Reader, read: (Reader) -> number): { number }
	local n = ru32(r)
	local out = table.create(n)
	for i = 1, n do
		out[i] = read(r)
	end
	return out
end

--[=[
	@within NavMeshSerialize
	A mesh from a buffer made by `Serialize`. Errors on another format version or a damaged
	buffer.
]=]
function Serialize.Deserialize(data: buffer): State
	if typeof(data) ~= "buffer" then
		error("NavMesh.Deserialize: expected a buffer", 0)
	end
	local r: Reader = { Buffer = data, At = 0 }
	if buffer.len(data) < 6 or buffer.readstring(data, take(r, 4), 4) ~= MAGIC then
		error("NavMesh.Deserialize: not a NavMesh bake", 0)
	end
	local version = ru16(r)
	if version ~= VERSION then
		error(`NavMesh.Deserialize: unsupported format version {version} (this build reads {VERSION})`, 0)
	end
	local s = Storage.New()
	local cap = rf64(r)

	for f = 1, ru32(r) do
		Storage.InsertFloor(s, rstr(r))
		local tileSize, defaultArea = rf64(r), ru32(r)
		local areaIds = rlist(r, ru32)
		local rings = {}
		for i = 1, ru32(r) do
			rings[i] = { X = rlist(r, ri32), Z = rlist(r, ri32), Y = rlist(r, rf64) }
		end
		Storage.SetFloorSources(s, f, tileSize, defaultArea, areaIds, rings)
	end

	local tileCount = ru32(r)
	for tile = 1, tileCount do
		local floor = ru32(r)
		local x0, z0, x1, z1 = rf64(r), rf64(r), rf64(r), rf64(r)
		Storage.InsertTile(s, floor, x0, z0, x1, z1)
		Storage.SetTileStamp(s, tile, ru32(r))
		Storage.SetTileSources(s, tile, rlist(r, ri32), rlist(r, ru32), rlist(r, ru32), rlist(r, ru32))
	end

	for v = 1, ru32(r) do
		Storage.AddVertex(s, rvec(r))
		Storage.SetWallVertex(s, v, ru8(r) == 1)
	end

	for tile = 1, tileCount do
		local count = ru32(r)
		local first = Storage.AllocTileRange(s, tile, count)
		for t = first, first + count - 1 do
			Storage.SetTriangle(s, t, ru32(r), ru32(r), ru32(r))
			for e = 1, 3 do
				Storage.SetNeighbor(s, t, e, ru32(r))
			end
			Storage.SetTriangleArea(s, t, ru32(r))
			local open = ru8(r)
			for e = 1, 3 do
				if bit32.btest(open, bit32.lshift(1, e - 1)) then
					Storage.SetEdgeOpen(s, t, e)
				end
			end
			for k = 1, 3 do
				Storage.SetCornerWidth(s, t, k, rf64(r))
				Storage.SetPortalWidth(s, t, k, rf64(r))
			end
		end
	end

	for _ = 1, ru32(r) do
		Storage.InsertSeam(s, ru32(r), ru32(r), ri32(r), ri32(r), ri32(r), ri32(r))
	end
	for _ = 1, ru32(r) do
		Storage.InsertPiece(s, ru32(r), ru32(r), ru8(r))
	end

	for id = 1, ru32(r) do
		local fromTri, from, toTri, to, cost, area = ru32(r), rvec(r), ru32(r), rvec(r), rf64(r), ru32(r)
		local label = rstr(r)
		local flags = ru8(r)
		Storage.InsertLink(s, fromTri, from, toTri, to, cost, area, label, bit32.btest(flags, 1))
		Storage.SetLinkFlag(s, id, bit32.btest(flags, 2))
	end

	for id = 1, ru32(r) do
		local floor, state = ru32(r), ru8(r)
		Storage.InsertObstacleRecord(s, floor, rlist(r, ri32), rlist(r, ri32))
		Storage.SetObstacleState(s, id, state)
	end

	if r.At ~= buffer.len(data) then
		error("NavMesh.Deserialize: the buffer has trailing bytes (corrupt)", 0)
	end
	Storage.SetMaxAgentRadius(s, cap)
	Build.Internal.Connect(s)
	return s
end

return Serialize
