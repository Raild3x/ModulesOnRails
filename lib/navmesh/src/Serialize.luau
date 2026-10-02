--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshSerialize
	@private

	The versioned byte format for baked meshes (SR9, P3). It is written and read through Storage
	accessors only, so it is independent of the in-memory layout: swapping `Storage.luau` never
	changes old bakes.

	**Layout (v3, 2026-09-28):** "NVMS", a u16 version (3), then tagged sections: a u16 tag, a
	u32 byte length and the payload. Tags are written in ascending order, each once.
	- Bit 15 of a tag (0x8000) marks it required. A reader skips an optional section it doesn't
	  know and errors on a required one ("needs a newer build"), so later fields don't need a
	  new version.
	- A section's layout never changes: a new layout gets a new tag. A known section must be
	  read to exactly its stated length.
	- Stored are the inputs Update replays (authored rings, obstacle and link records), never
	  what can be derived from them.

	| tag | section |
	|---|---|
	| 0x8001 | the radius cap (f64) |
	| 0x8002 | floors: name, tile size, default area, area ids, then every authored ring (group, grid X/Z as i32, heights as f64) |
	| 0x8003 | tiles: floor, bounds (f64), stamp |
	| 0x8004 | vertices (f32 X/Y/Z, as stored, plus the wall flag) |
	| 0x8005 | per tile, its triangles: vertices, neighbours, area, open edges, corner and portal widths (f64) |
	| 0x8006 | seams, then seam pieces |
	| 0x0001 | link names (optional, written only when a link has one): count, then (link id, name) |
	| 0x8007 | links: the next link id, then records with their ids (sparse, like obstacles) and flags: 1 both ways, 2 enabled, 4 pending add, 8 pending removal |
	| 0x8008 | obstacles: the next obstacle id, then the live records (id, floor, state, quantized ring) |

	A pending add (ticket 30) is stored as the caller gave it: no triangles, its points unsnapped,
	and cost -1 when it takes the default. Link names are optional: a reader that skips them
	still has every link, just not `SetLinkEnabled` by name.

	Reserved for later (not written yet): ticket 29's headroom source (the `FloorDesc.Headroom`
	rings), and Track D's
	simplification tolerance (rings are stored simplified, so it is only metadata).

	Extra links (seam portals and links) are derived data: `Deserialize` rebuilds them exactly
	as Build does.

	A buffer of another version errors on `Deserialize` (SR9): v1 (2026-09-27) and v2
	(2026-09-28, which stored each tile's snapped triangulation input and not the authored
	obstacle and area rings) bakes error with a message to rebuild them.
]=]

local Build = require("./Build")
local Storage = require("./Storage")

type State = Storage.State

local MAGIC = "NVMS"
local VERSION = 3
local REQUIRED = 0x8000

local TAG_LINK_NAMES = 0x0001
local TAG_CAP = 0x8001
local TAG_FLOORS = 0x8002
local TAG_TILES = 0x8003
local TAG_VERTICES = 0x8004
local TAG_TRIANGLES = 0x8005
local TAG_SEAMS = 0x8006
local TAG_LINKS = 0x8007
local TAG_OBSTACLES = 0x8008

local Serialize = {}

-- A growing byte writer.
type Writer = { Buffer: buffer, Size: number }

local function writer(): Writer
	return { Buffer = buffer.create(1024), Size = 0 }
end

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

-- Writes one section: its tag, its payload's length, the payload.
local function section(w: Writer, tag: number, write: (Writer) -> ())
	local body = writer()
	write(body)
	u16(w, tag)
	u32(w, body.Size)
	reserve(w, body.Size)
	buffer.copy(w.Buffer, w.Size, body.Buffer, 0, body.Size)
	w.Size += body.Size
end

--[=[
	@within NavMeshSerialize
	The mesh as a versioned buffer.
]=]
function Serialize.Serialize(s: State): buffer
	local w = writer()
	reserve(w, 4)
	buffer.writestring(w.Buffer, 0, MAGIC)
	w.Size = 4
	u16(w, VERSION)

	local named = {}
	for slot = 1, Storage.LinkCount(s) do
		if Storage.GetLinkName(s, slot) ~= "" then
			table.insert(named, slot)
		end
	end
	if #named > 0 then
		section(w, TAG_LINK_NAMES, function(b)
			u32(b, #named)
			for _, slot in named do
				u32(b, Storage.GetLinkId(s, slot))
				str(b, Storage.GetLinkName(s, slot))
			end
		end)
	end
	section(w, TAG_CAP, function(b)
		f64(b, Storage.GetMaxAgentRadius(s))
	end)
	section(w, TAG_FLOORS, function(b)
		u32(b, Storage.FloorCount(s))
		for f = 1, Storage.FloorCount(s) do
			str(b, Storage.GetFloorName(s, f))
			local tileSize, defaultArea, areaIds, rings, groups = Storage.GetFloorSources(s, f)
			f64(b, tileSize)
			u32(b, defaultArea)
			list(b, areaIds, u32)
			u32(b, #rings)
			for i, ring in rings do
				u32(b, groups[i])
				list(b, ring.X, i32)
				list(b, ring.Z, i32)
				list(b, ring.Y, f64)
			end
		end
	end)
	section(w, TAG_TILES, function(b)
		u32(b, Storage.TileCount(s))
		for tile = 1, Storage.TileCount(s) do
			u32(b, Storage.GetTileFloor(s, tile))
			for _, v in { Storage.GetTileBounds(s, tile) } do
				f64(b, v)
			end
			u32(b, Storage.GetTileStamp(s, tile))
		end
	end)
	section(w, TAG_VERTICES, function(b)
		u32(b, Storage.VertexCount(s))
		for v = 1, Storage.VertexCount(s) do
			vec(b, Storage.GetVertex(s, v))
			u8(b, if Storage.IsWallVertex(s, v) then 1 else 0)
		end
	end)
	section(w, TAG_TRIANGLES, function(b)
		for tile = 1, Storage.TileCount(s) do
			local first, count = Storage.GetTileRange(s, tile)
			u32(b, count)
			for t = first, first + count - 1 do
				for _, v in { Storage.GetTriangle(s, t) } do
					u32(b, v)
				end
				for e = 1, 3 do
					u32(b, Storage.GetNeighbor(s, t, e))
				end
				u32(b, Storage.GetTriangleArea(s, t))
				local open = 0
				for e = 1, 3 do
					if Storage.IsEdgeOpen(s, t, e) then
						open += bit32.lshift(1, e - 1)
					end
				end
				u8(b, open)
				for k = 1, 3 do
					f64(b, Storage.GetCornerWidth(s, t, k))
					f64(b, Storage.GetPortalWidth(s, t, k))
				end
			end
		end
	end)
	section(w, TAG_SEAMS, function(b)
		u32(b, Storage.SeamCount(s))
		for seam = 1, Storage.SeamCount(s) do
			local fa, fb, ax, az, bx, bz = Storage.GetSeam(s, seam)
			u32(b, fa)
			u32(b, fb)
			for _, v in { ax, az, bx, bz } do
				i32(b, v)
			end
		end
		u32(b, Storage.PieceCount(s))
		for piece = 1, Storage.PieceCount(s) do
			local seam, tri, edge = Storage.GetPiece(s, piece)
			u32(b, seam)
			u32(b, tri)
			u8(b, edge)
		end
	end)
	section(w, TAG_LINKS, function(b)
		u32(b, Storage.GetLinkNextId(s))
		u32(b, Storage.LinkCount(s))
		for slot = 1, Storage.LinkCount(s) do
			local fromTri, from, toTri, to, cost, area, label, both, enabled = Storage.GetLink(s, slot)
			local state = Storage.GetLinkState(s, slot)
			u32(b, Storage.GetLinkId(s, slot))
			u32(b, fromTri)
			vec(b, from)
			u32(b, toTri)
			vec(b, to)
			f64(b, cost)
			u32(b, area)
			str(b, label)
			u8(
				b,
				(if both then 1 else 0)
					+ (if enabled then 2 else 0)
					+ (if state == Storage.OBSTACLE_PENDING_ADD then 4 else 0)
					+ (if state == Storage.OBSTACLE_PENDING_REMOVE then 8 else 0)
			)
		end
	end)
	section(w, TAG_OBSTACLES, function(b)
		u32(b, Storage.GetObstacleNextId(s))
		u32(b, Storage.ObstacleCount(s))
		for slot = 1, Storage.ObstacleCount(s) do
			local id, floor, state, xs, zs = Storage.GetObstacleRecord(s, slot)
			u32(b, id)
			u32(b, floor)
			u8(b, state)
			list(b, xs, i32)
			list(b, zs, i32)
		end
	end)

	local out = buffer.create(w.Size)
	buffer.copy(out, 0, w.Buffer, 0, w.Size)
	return out
end

-- A byte reader over part of a buffer: [At, End).
type Reader = { Buffer: buffer, At: number, End: number }

local function corrupt(): never
	error("NavMesh.Deserialize: the buffer is truncated or corrupt", 0)
end

local function take(r: Reader, bytes: number): number
	local at = r.At
	if at + bytes > r.End then
		corrupt()
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
	local r: Reader = { Buffer = data, At = 0, End = buffer.len(data) }
	if buffer.len(data) < 6 or buffer.readstring(data, take(r, 4), 4) ~= MAGIC then
		error("NavMesh.Deserialize: not a NavMesh bake", 0)
	end
	local version = ru16(r)
	if version == 1 or version == 2 then
		error(
			`NavMesh.Deserialize: this is a format v{version} bake, which this build no longer reads (it reads v{VERSION}); rebuild it: NavMesh.Build the description, then NavMesh.Serialize`,
			0
		)
	elseif version ~= VERSION then
		error(`NavMesh.Deserialize: unsupported format version {version} (this build reads {VERSION})`, 0)
	end

	-- The sections, in ascending tag order (which also rules out repeats).
	local sections: { [number]: Reader } = {}
	local last = 0
	while r.At < r.End do
		local tag, length = ru16(r), ru32(r)
		if tag <= last then
			corrupt()
		end
		last = tag
		local at = take(r, length)
		sections[tag] = { Buffer = data, At = at, End = at + length }
	end
	for tag in sections do
		if bit32.btest(tag, REQUIRED) and (tag < TAG_CAP or tag > TAG_OBSTACLES) then
			error(
				`NavMesh.Deserialize: the bake needs a newer build (it has required section {string.format(
					"0x%04X",
					tag
				)})`,
				0
			)
		end
	end
	-- A known section, which must be read to exactly its length.
	local function read(tag: number, body: (Reader) -> ())
		local sr = sections[tag]
		if sr == nil then
			corrupt()
		end
		body(sr)
		if sr.At ~= sr.End then
			corrupt()
		end
	end

	local s = Storage.New()
	local cap = 0
	read(TAG_CAP, function(b)
		cap = rf64(b)
	end)
	read(TAG_FLOORS, function(b)
		for f = 1, ru32(b) do
			Storage.InsertFloor(s, rstr(b))
			local tileSize, defaultArea = rf64(b), ru32(b)
			local areaIds = rlist(b, ru32)
			local rings, groups = {}, {}
			for i = 1, ru32(b) do
				groups[i] = ru32(b)
				rings[i] = { X = rlist(b, ri32), Z = rlist(b, ri32), Y = rlist(b, rf64) }
			end
			Storage.SetFloorSources(s, f, tileSize, defaultArea, areaIds, rings, groups)
		end
	end)
	local tileCount = 0
	read(TAG_TILES, function(b)
		tileCount = ru32(b)
		for tile = 1, tileCount do
			local floor = ru32(b)
			local x0, z0, x1, z1 = rf64(b), rf64(b), rf64(b), rf64(b)
			Storage.InsertTile(s, floor, x0, z0, x1, z1)
			Storage.SetTileStamp(s, tile, ru32(b))
		end
	end)
	read(TAG_VERTICES, function(b)
		for v = 1, ru32(b) do
			Storage.AddVertex(s, rvec(b))
			Storage.SetWallVertex(s, v, ru8(b) == 1)
		end
	end)
	read(TAG_TRIANGLES, function(b)
		for tile = 1, tileCount do
			local count = ru32(b)
			local first = Storage.AllocTileRange(s, tile, count)
			for t = first, first + count - 1 do
				Storage.SetTriangle(s, t, ru32(b), ru32(b), ru32(b))
				for e = 1, 3 do
					Storage.SetNeighbor(s, t, e, ru32(b))
				end
				Storage.SetTriangleArea(s, t, ru32(b))
				local open = ru8(b)
				for e = 1, 3 do
					if bit32.btest(open, bit32.lshift(1, e - 1)) then
						Storage.SetEdgeOpen(s, t, e)
					end
				end
				for k = 1, 3 do
					Storage.SetCornerWidth(s, t, k, rf64(b))
					Storage.SetPortalWidth(s, t, k, rf64(b))
				end
			end
		end
	end)
	read(TAG_SEAMS, function(b)
		for _ = 1, ru32(b) do
			Storage.InsertSeam(s, ru32(b), ru32(b), ri32(b), ri32(b), ri32(b), ri32(b))
		end
		for _ = 1, ru32(b) do
			Storage.InsertPiece(s, ru32(b), ru32(b), ru8(b))
		end
	end)
	read(TAG_LINKS, function(b)
		local nextId = ru32(b)
		for slot = 1, ru32(b) do
			local id = ru32(b)
			local fromTri, from, toTri, to, cost, area = ru32(b), rvec(b), ru32(b), rvec(b), rf64(b), ru32(b)
			local label = rstr(b)
			local flags = ru8(b)
			-- Ids increase and stay below the next id; a pending add has no triangles, and only it
			-- may have the default cost (-1); a link is not both added and removed.
			local adding = bit32.btest(flags, 4)
			if
				id < Storage.GetLinkNextId(s)
				or id >= nextId
				or flags >= 16
				or (adding and (bit32.btest(flags, 8) or fromTri ~= 0 or toTri ~= 0))
				or not (cost >= 0 or (adding and cost == -1))
			then
				corrupt()
			end
			Storage.InsertLink(s, fromTri, from, toTri, to, cost, area, label, bit32.btest(flags, 1), "", id)
			Storage.SetLinkFlag(s, slot, bit32.btest(flags, 2))
			if adding then
				Storage.SetLinkState(s, slot, Storage.OBSTACLE_PENDING_ADD)
			elseif bit32.btest(flags, 8) then
				Storage.SetLinkState(s, slot, Storage.OBSTACLE_PENDING_REMOVE)
			end
		end
		Storage.SetLinkNextId(s, math.max(nextId, 1))
	end)
	if sections[TAG_LINK_NAMES] then
		read(TAG_LINK_NAMES, function(b)
			for _ = 1, ru32(b) do
				local slot = Storage.FindLink(s, ru32(b))
				local name = rstr(b)
				if slot == 0 or name == "" then
					corrupt()
				end
				Storage.SetLinkName(s, slot, name)
			end
		end)
	end
	read(TAG_OBSTACLES, function(b)
		local nextId = ru32(b)
		for slot = 1, ru32(b) do
			local id, floor, state = ru32(b), ru32(b), ru8(b)
			-- Ids increase and stay below the next id; a record is pending or active.
			if
				id < Storage.GetObstacleNextId(s)
				or id >= nextId
				or state < 1
				or state > Storage.OBSTACLE_PENDING_REMOVE
			then
				corrupt()
			end
			Storage.InsertObstacleRecord(s, floor, rlist(b, ri32), rlist(b, ri32), id)
			Storage.SetObstacleState(s, slot, state)
		end
		Storage.SetObstacleNextId(s, math.max(nextId, 1))
	end)

	Storage.SetMaxAgentRadius(s, cap)
	Build.Internal.Connect(s)
	return s
end

return Serialize
