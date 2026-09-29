--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshTiles
	@private

	Dynamic obstacles (ticket 18): `AddObstacle`, `RemoveObstacle` and `Update`.

	**Records:** an obstacle is validated and quantized when added (SR13: a bad polygon errors
	at the call). Adding and removing only record the change; `Update` applies every pending
	change at once. A removed obstacle's record is freed when `Update` commits, and a pending add
	that is removed goes at once, so a door toggled all day keeps one record. Ids come from a
	counter that only grows: never reused, and a freed id still reads as "already removed".

	**Dirty tiles:** the stored tiles on the obstacle's floor whose rectangle, grown by one grid
	pixel, overlaps its snapped bounding box (SR13). New hot pixels then never land on a clean
	tile's border, so clean tiles never change.

	**Rebuild (v3, 2026-09-28):** the dirty tiles of a floor go through Build's own snap rounding
	and clipping (`Build.Internal.TileInputs`), fed the floor's authored rings and seams near them
	plus the active obstacles near them, placed after the static obstacles as if baked. That is
	exactly the input a fresh Build with those obstacles gives them (SR14), so add-then-remove
	reproduces a fresh Build. (Before v3, Update re-snapped each tile's already-snapped input,
	which could round a crossing to the next pixel.) Every dirty tile is triangulated by Build's
	own `TriangulateTile`.

	**Commit (atomic, SR13/SR14; ticket 22 made it local):**
	- Everything that can fail runs first, reading the mesh only: the rebuilt tiles are
	  triangulated and checked in scratch (CopyOut's checks), and their vertices interned by grid
	  point against the dirty tiles and their neighbours, the only tiles that can share one.
	- A fresh state is then built. Data an Update never changes (floors, tiles, rebuild sources,
	  seams) is shared, not copied. Clean tiles are copied as buffer ranges and renumbered in one
	  pass; rebuilt tiles are written into their new ranges. Freed vertex slots take the new
	  vertices and the highest live vertices move down into the rest, so nothing is left behind:
	  toggling a door never grows memory, and ids are only stable until the next Update.
	- Cross-tile neighbours are relinked around the rebuilt tiles; seam portals and links are
	  rebuilt (links re-snap onto the new triangles).
	- Clearance: a rebuilt triangle with an old one's grid points keeps its widths; new ones, and
	  every triangle within its own reach r* of a changed wall, are recomputed (ruling U-a;
	  `Clearance.Refresh`, which keeps a wall index across Updates).
	- Stamps are bumped for every tile whose triangles or widths changed, and for the tiles at
	  the ends of every link.
	- The changed regions are returned: per floor, boxes holding everything whose meaning
	  changed (the rebuilt tiles' triangles, old and new, and the triangles whose widths were
	  recomputed).
	- The state is swapped in only when all of that succeeded. On an error the mesh is
	  untouched, the pending records are rolled back, and the error is raised again.

	**Cost:** the dirty tiles' re-snap, triangulation and clearance, plus an O(T) range copy and
	renumbering pass (buffer operations, about 0.1-0.2 ms per 1,000 triangles) and O(tiles) loops.
]=]

local Build = require("./Build")
local Clearance = require("./Clearance")
local Snap = require("./Snap")
local Storage = require("./Storage")
local Types = require("./Types")

local Internal = Build.Internal
local GRID = Internal.GRID
local PointKey = Internal.PointKey
local EDGE_KEY = Internal.EDGE_KEY
local GROUP_OBSTACLE = Internal.GROUP_OBSTACLE
local Orient2D = require("../ConstrainedDelaunay").Orient2D

type State = Storage.State

local LINK_EXTENTS = vector.create(0.5, 4, 0.5)

local Tiles = {}

--[=[
	@within NavMeshTiles
	Validates and records an obstacle on floor `floorName` (pending until `Update`). Returns its
	id, which is never reused.
]=]
function Tiles.AddObstacle(s: State, floorName: string, polygon: Types.Polygon): number
	local floor = 0
	for f = 1, Storage.FloorCount(s) do
		if Storage.GetFloorName(s, f) == floorName then
			floor = f
		end
	end
	if floor == 0 then
		error(`NavMesh.AddObstacle: no floor '{floorName}'`, 3)
	end
	local ok, ring = pcall(Internal.QuantizeRing, polygon, `obstacle on floor '{floorName}'`)
	if not ok then
		error((tostring(ring):gsub("^NavMesh.Build:", "NavMesh.AddObstacle:")), 3)
	end
	return Storage.InsertObstacleRecord(s, floor, (ring :: any).X, (ring :: any).Z)
end

--[=[
	@within NavMeshTiles
	Records the removal of obstacle `id` (pending until `Update`).
]=]
function Tiles.RemoveObstacle(s: State, id: number)
	if type(id) ~= "number" or id % 1 ~= 0 or id < 1 or id >= Storage.GetObstacleNextId(s) then
		error(`NavMesh.RemoveObstacle: no obstacle {id}`, 3)
	end
	local slot = Storage.FindObstacle(s, id)
	local state = if slot ~= 0 then Storage.GetObstacleState(s, slot) else 0
	if state == Storage.OBSTACLE_PENDING_ADD then
		Storage.RemoveObstacleRecord(s, slot) -- never applied: nothing for Update to undo
	elseif state == Storage.OBSTACLE_ACTIVE then
		Storage.SetObstacleState(s, slot, Storage.OBSTACLE_PENDING_REMOVE)
	else
		-- Pending removal, or already dropped by an Update (its record is freed).
		error(`NavMesh.RemoveObstacle: obstacle {id} is already removed`, 3)
	end
end

-- Grid bounds of a ring.
local function bounds(xs: { number }, zs: { number }): (number, number, number, number)
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, #xs do
		x0, x1 = math.min(x0, xs[i]), math.max(x1, xs[i])
		z0, z1 = math.min(z0, zs[i]), math.max(z1, zs[i])
	end
	return x0, z0, x1, z1
end

-- Tile rectangle in grid units.
local function tileRect(s: State, tile: number): (number, number, number, number)
	local x0, z0, x1, z1 = Storage.GetTileBounds(s, tile)
	return math.round(x0 * GRID), math.round(z0 * GRID), math.round(x1 * GRID), math.round(z1 * GRID)
end

-- Per mesh (weak), per floor: the walkable rings' height surfaces (Build.Internal.MakeSurface),
-- by ring index. Rings never change after Build, so they are made once, on the first Update;
-- runtime state, never serialized.
local surfaceCache: { [State]: { [number]: { [number]: any } } } = setmetatable({}, { __mode = "k" }) :: any

local function surfacesOf(s: State, floor: number): { [number]: any }
	local floors = surfaceCache[s] or {}
	surfaceCache[s] = floors
	local surfaces = floors[floor]
	if surfaces == nil then
		surfaces = {}
		local _, _, _, rings, groups = Storage.GetFloorSources(s, floor)
		for i, ring in rings do
			if groups[i] == Internal.GROUP_WALKABLE then
				surfaces[i] = Internal.MakeSurface(ring)
			end
		end
		floors[floor] = surfaces
	end
	return surfaces
end

type Obstacle = { Id: number, Floor: number, X: { number }, Z: { number }, Box: { number } }

-- The triangulation input for each of a floor's dirty tiles: Build's own snap rounding and
-- clipping, fed the floor's authored rings and seams within a pixel of those tiles and the active
-- obstacles there, after the static ones as if baked (SR14). `Build.Internal.TileInputs` says
-- why that is exactly Build's input.
-- ponytail: whole rings near the tiles are re-snapped (a planar 8,192-point ring near a change
-- costs about 19 ms); a per-ring edge index if huge authored rings show up.
local function reSnap(
	s: State,
	floor: number,
	tiles: { number },
	obstacles: { Obstacle },
	surfaces: { [number]: any }
): { [number]: any }
	local tileSize, _, _, rings, groups = Storage.GetFloorSources(s, floor)
	local only: { number } = {}
	local tileAt: { [number]: number } = {}
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, tile in tiles do
		local tx0, tz0, tx1, tz1 = tileRect(s, tile)
		table.insert(only, tx0)
		table.insert(only, tz0)
		tileAt[PointKey(tx0, tz0)] = tile
		x0, z0 = math.min(x0, tx0 - 1), math.min(z0, tz0 - 1)
		x1, z1 = math.max(x1, tx1 + 1), math.max(z1, tz1 + 1)
	end
	local sources = {}
	local function add(ring: any, group: number, surface: any)
		local bx0, bz0, bx1, bz1 = bounds(ring.X, ring.Z)
		if bx0 <= x1 and x0 <= bx1 and bz0 <= z1 and z0 <= bz1 then
			table.insert(sources, { Ring = ring, Group = group, Surface = surface })
		end
	end
	for r, ring in rings do
		if groups[r] <= GROUP_OBSTACLE then
			add(ring, groups[r], surfaces[r])
		end
	end
	for _, obstacle in obstacles do
		add(obstacle, GROUP_OBSTACLE, nil)
	end
	for r, ring in rings do
		if groups[r] > GROUP_OBSTACLE then
			add(ring, groups[r], nil)
		end
	end
	local seams = {}
	for id = 1, Storage.SeamCount(s) do
		local a, b, ax, az, bx, bz = Storage.GetSeam(s, id)
		if
			(a == floor or b == floor)
			and math.min(ax, bx) <= x1
			and x0 <= math.max(ax, bx)
			and math.min(az, bz) <= z1
			and z0 <= math.max(az, bz)
		then
			table.insert(seams, { Id = id, AX = ax, AZ = az, BX = bx, BZ = bz })
		end
	end
	local inputs = {}
	for _, input in (Internal.TileInputs(sources, seams, tileSize, only)) do
		inputs[tileAt[PointKey(input.X0, input.Z0)]] = input
	end
	return inputs
end

-- A rebuilt tile, validated and ready to write: vertex ids (> 0 an existing vertex, < 0 the
-- k-th new vertex as -k until slots are assigned), areas, in-tile neighbours and seam pieces.
type Scratch = {
	Verts: { number }, -- 3 per triangle
	Areas: { number },
	Neighbors: { number }, -- 3 per triangle, tile-local (0 = none)
	Pieces: { number }, -- seam, local triangle, edge
}

-- What `prepare` hands the commit.
type Plan = {
	PendingFloors: { [number]: { { number } } },
	Dirty: { [number]: boolean },
	DirtyList: { number }, -- in tile order
	NearList: { number }, -- the clean tiles touching a dirty one
	Scratch: { [number]: Scratch },
	NewVerts: { vector }, -- positions of the new vertices
	NewSlot: { number }, -- new vertex k -> its id
	Moved: { [number]: number }, -- live vertex above the final count -> its new id
	OldDirtyVerts: { [number]: boolean }, -- vertices of the old dirty tiles
	Freed: { [number]: boolean },
	FinalVertexCount: number,
	FinalTriangleCount: number,
	NewFirst: { number }, -- tile -> first triangle in the new state
	SegStart: { number }, -- old triangle ids: segment starts...
	SegDelta: { number | false }, -- ...and their shift (false = a dirty range, removed)
}

-- Everything up to the commit, reading `s` only: pending changes, dirty tiles and their clean
-- neighbours, the rebuilt tiles validated in scratch (every check CopyOut makes), the vertex
-- slots, and how the triangle ranges shift.
local function prepare(s: State): Plan
	local pendingFloors: { [number]: { { number } } } = {}
	local active: { [number]: { Obstacle } } = {}
	for slot = 1, Storage.ObstacleCount(s) do
		local id, floor, state, xs, zs = Storage.GetObstacleRecord(s, slot)
		local x0, z0, x1, z1 = bounds(xs, zs)
		if state == Storage.OBSTACLE_PENDING_ADD or state == Storage.OBSTACLE_PENDING_REMOVE then
			local list = pendingFloors[floor] or {}
			pendingFloors[floor] = list
			table.insert(list, { x0, z0, x1, z1 })
		end
		if state == Storage.OBSTACLE_PENDING_ADD or state == Storage.OBSTACLE_ACTIVE then
			local list = active[floor] or {}
			active[floor] = list
			table.insert(list, { Id = id, Floor = floor, X = xs, Z = zs, Box = { x0, z0, x1, z1 } })
		end
	end

	-- Dirty tiles through the tile hash (O(dirty), not O(tiles)): the tiles meeting the snapped
	-- box grown by a pixel. Then their clean neighbours: the tiles whose closed rectangle touches
	-- a dirty one.
	local dirty: { [number]: boolean } = {}
	local dirtyByFloor: { [number]: { number } } = {}
	for floor, boxes in pendingFloors do
		for _, box in boxes do
			local x0, z0 = (box[1] - 1) / GRID, (box[2] - 1) / GRID
			local x1, z1 = (box[3] + 1) / GRID, (box[4] + 1) / GRID
			for _, tile in Snap.TilesIn(s, floor, x0, z0, x1, z1) do
				if not dirty[tile] then
					dirty[tile] = true
					local list = dirtyByFloor[floor] or {}
					dirtyByFloor[floor] = list
					table.insert(list, tile)
				end
			end
		end
	end
	local near: { [number]: boolean } = {}
	local nearByFloor: { [number]: { number } } = {}
	local nearList: { number } = {}
	for floor, tiles in dirtyByFloor do
		table.sort(tiles)
		for _, d in tiles do
			for _, tile in Snap.TilesIn(s, floor, Storage.GetTileBounds(s, d)) do
				if not dirty[tile] and not near[tile] then
					near[tile] = true
					local list = nearByFloor[floor] or {}
					nearByFloor[floor] = list
					table.insert(list, tile)
					table.insert(nearList, tile)
				end
			end
		end
	end

	-- Heights and vertex ids by grid point, from the dirty tiles and their neighbours only: a
	-- rebuilt tile's vertices all lie in its closed rectangle, where no other tile has one.
	local floorHeights: { [number]: { [number]: number } } = {}
	local floorKeyVertex: { [number]: { [number]: number } } = {}
	local oldDirtyVerts: { [number]: boolean } = {}
	local nearVerts: { [number]: boolean } = {}
	for floor, tiles in dirtyByFloor do
		local heights, keyVertex = {}, {}
		local function scan(tile: number, into: { [number]: boolean })
			local first, count = Storage.GetTileRange(s, tile)
			for t = first, first + count - 1 do
				for _, v in { Storage.GetTriangle(s, t) } do
					local p = Storage.GetVertex(s, v)
					local key = PointKey(math.round(p.X * GRID), math.round(p.Z * GRID))
					heights[key] = p.Y
					keyVertex[key] = v
					into[v] = true
				end
			end
		end
		for _, tile in tiles do
			scan(tile, oldDirtyVerts)
		end
		local nearTiles: { number } = nearByFloor[floor] or {}
		for _, tile in nearTiles do
			scan(tile, nearVerts)
		end
		floorHeights[floor] = heights
		floorKeyVertex[floor] = keyVertex
	end

	-- New triangles for each dirty tile.
	local rebuilt: { [number]: { any } } = {}
	local rebuiltInput: { [number]: any } = {}
	for floor, tiles in dirtyByFloor do
		local _, defaultArea, areaIds = Storage.GetFloorSources(s, floor)
		local surfaces = surfacesOf(s, floor)
		local floorData = {
			Context = `floor '{Storage.GetFloorName(s, floor)}'`,
			Surfaces = surfaces,
			AreaIds = areaIds,
			DefaultArea = defaultArea,
			Heights = floorHeights[floor],
			HeightFrom = {},
		}
		-- Every dirty tile is re-snapped from the floor's rings, with the active obstacles.
		local inputs = reSnap(s, floor, tiles, active[floor] or {}, surfaces)
		for _, tile in tiles do
			local input = inputs[tile]
			if input == nil then
				error("NavMesh.Update: internal error: a stored tile has no walkable input", 0)
			end
			rebuiltInput[tile] = input
			rebuilt[tile] = Internal.TriangulateTile(input.Coords, input.Edges, input.Groups, floorData)
		end
	end

	-- Scratch: vertices interned by grid point (existing ids reused, new ones numbered -k), and
	-- CopyOut's checks run before anything is written.
	local dirtyList: { number } = {}
	for tile in dirty do
		table.insert(dirtyList, tile)
	end
	table.sort(dirtyList)
	local newVerts: { vector } = {}
	local reused: { [number]: boolean } = {}
	local scratch: { [number]: Scratch } = {}
	for _, tile in dirtyList do
		local floor = Storage.GetTileFloor(s, tile)
		local context = `floor '{Storage.GetFloorName(s, floor)}'`
		local heights, keyVertex = floorHeights[floor], floorKeyVertex[floor]
		local input = rebuiltInput[tile]
		local seamOf = Internal.SeamFragments(input.Coords, input.Edges, input.Seams)
		local hasSeams = next(seamOf) ~= nil
		local out: Scratch = { Verts = {}, Areas = {}, Neighbors = {}, Pieces = {} }
		for i, tri in rebuilt[tile] do
			local ps = {}
			for k = 1, 3 do
				local key = tri.Keys[k]
				local id = keyVertex[key]
				if id == nil then
					table.insert(newVerts, vector.create(tri.X[k] / GRID, heights[key], tri.Z[k] / GRID))
					id = -#newVerts
					keyVertex[key] = id
				elseif id > 0 then
					reused[id] = true
				end
				table.insert(out.Verts, id)
				ps[k] = if id > 0 then Storage.GetVertex(s, id) else newVerts[-id]
				table.insert(out.Neighbors, tri.Neighbors[k])
			end
			table.insert(out.Areas, tri.Area)
			if hasSeams then
				for e = 1, 3 do
					local ka, kb = tri.Keys[e % 3 + 1], tri.Keys[(e + 1) % 3 + 1]
					local seamId = seamOf[if ka < kb then `{ka}:{kb}` else `{kb}:{ka}`]
					if seamId ~= nil then
						table.move({ seamId, i, e }, 1, 3, #out.Pieces + 1, out.Pieces)
					end
				end
			end
			-- CopyOut's degeneracy guard (SR2), on the stored (f32) coordinates.
			local pa, pb, pc = ps[1], ps[2], ps[3]
			if Orient2D(pa.X, pa.Z, pb.X, pb.Z, pc.X, pc.Z) <= 0 then
				Internal.Fail(
					context,
					`a triangle degenerates after quantization near ({Internal.Fmt(pa.X)}, {Internal.Fmt(pa.Z)})`
				)
			end
		end
		scratch[tile] = out
	end

	-- Vertex slots. Freed: the old dirty tiles' vertices that no neighbour or rebuilt tile uses.
	-- New vertices fill the lowest freed slots, then the highest live vertices move down into
	-- what is left, so the array stays compact (SR14).
	local freed: { number } = {}
	local isFreed: { [number]: boolean } = {}
	for v in oldDirtyVerts do
		if not nearVerts[v] and not reused[v] then
			table.insert(freed, v)
			isFreed[v] = true
		end
	end
	table.sort(freed)
	local oldCount = Storage.VertexCount(s)
	local finalCount = oldCount - #freed + #newVerts
	local slots = {}
	for _, v in freed do
		if v <= finalCount then
			table.insert(slots, v)
		end
	end
	for v = oldCount + 1, finalCount do
		table.insert(slots, v)
	end
	local newSlot: { number } = table.create(#newVerts)
	for k = 1, #newVerts do
		newSlot[k] = slots[k]
	end
	local moved: { [number]: number } = {}
	local nextSlot = #newVerts + 1
	for v = finalCount + 1, oldCount do
		if not isFreed[v] then
			moved[v] = slots[nextSlot]
			nextSlot += 1
		end
	end
	for _, out in scratch do
		local verts = out.Verts
		for i, id in verts do
			verts[i] = if id < 0 then newSlot[-id] else moved[id] or id
		end
	end

	-- The new triangle layout, tile by tile, and old-id segments: each clean run keeps one
	-- shift, each dirty range goes (false).
	local segStart: { number } = {}
	local segDelta: { number | false } = {}
	local newFirst: { number } = {}
	local cursor = 1
	for tile = 1, Storage.TileCount(s) do
		local first, count = Storage.GetTileRange(s, tile)
		newFirst[tile] = cursor
		local delta: number | false = if dirty[tile] then false else cursor - first
		if count > 0 and (#segDelta == 0 or segDelta[#segDelta] ~= delta) then
			table.insert(segStart, first)
			table.insert(segDelta, delta)
		end
		cursor += if dirty[tile] then #scratch[tile].Areas else count
	end

	return {
		PendingFloors = pendingFloors,
		Dirty = dirty,
		DirtyList = dirtyList,
		NearList = nearList,
		Scratch = scratch,
		NewVerts = newVerts,
		NewSlot = newSlot,
		Moved = moved,
		OldDirtyVerts = oldDirtyVerts,
		Freed = isFreed,
		FinalVertexCount = finalCount,
		FinalTriangleCount = cursor - 1,
		NewFirst = newFirst,
		SegStart = segStart,
		SegDelta = segDelta,
	}
end

-- Old triangle id -> new, through the plan's segments (0 when it was in a dirty tile).
local function remapTriangle(plan: Plan, t: number): number
	local segStart, segDelta = plan.SegStart, plan.SegDelta
	if #segStart == 0 or t < segStart[1] then
		return t
	end
	local i = 1
	while i < #segStart and t >= segStart[i + 1] do
		i += 1
	end
	local delta = segDelta[i]
	return if delta == false then 0 else t + (delta :: number)
end

-- A triangle's grid points, and its key: those points from the smallest one, in CCW order.
local function triangleKey(state: State, t: number): (string, number)
	local keys = {}
	for k, v in { Storage.GetTriangle(state, t) } do
		local p = Storage.GetVertex(state, v)
		keys[k] = PointKey(math.round(p.X * GRID), math.round(p.Z * GRID))
	end
	local first = if keys[1] < keys[2] and keys[1] < keys[3] then 1 elseif keys[2] < keys[3] then 2 else 3
	return `{keys[first]}:{keys[first % 3 + 1]}:{keys[(first + 1) % 3 + 1]}`, first
end

-- The changed regions (ticket 22): per floor, the boxes of the rebuilt tiles' triangles (old
-- and new) and of the triangles outside them whose widths were recomputed, merged wherever they
-- touch. Everything whose meaning changed lies inside:
-- triangles, neighbours, wall flags, seam pieces and link ends only change in the rebuilt tiles,
-- and widths only in recomputed triangles (a portal width a recomputed triangle writes for its
-- neighbour lies on their shared edge).
local function changedRegions(s: State, n: State, plan: Plan, recompute: { [number]: boolean }): { Types.ChangedRegion }
	local boxes: { { number } } = {} -- floor, min x, y, z, max x, y, z
	local function fit(box: { number }, state: State, t: number)
		for _, v in { Storage.GetTriangle(state, t) } do
			local p = Storage.GetVertex(state, v)
			box[2], box[3], box[4] = math.min(box[2], p.X), math.min(box[3], p.Y), math.min(box[4], p.Z)
			box[5], box[6], box[7] = math.max(box[5], p.X), math.max(box[6], p.Y), math.max(box[7], p.Z)
		end
	end
	for _, tile in plan.DirtyList do
		local box =
			{ Storage.GetTileFloor(n, tile), math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge }
		for _, state in { s, n } do
			local first, count = Storage.GetTileRange(state, tile)
			for t = first, first + count - 1 do
				fit(box, state, t)
			end
		end
		table.insert(boxes, box)
	end
	local byTile: { [number]: { number } } = {}
	for t in recompute do
		local tile = Storage.GetTriangleTile(n, t)
		if not plan.Dirty[tile] then
			local box = byTile[tile]
			if box == nil then
				box = {
					Storage.GetTileFloor(n, tile),
					math.huge,
					math.huge,
					math.huge,
					-math.huge,
					-math.huge,
					-math.huge,
				}
				byTile[tile] = box
				table.insert(boxes, box)
			end
			fit(box, n, t)
		end
	end
	-- ponytail: pairwise merging, quadratic in the boxes (one per rebuilt or re-widthed tile).
	local merged = true
	while merged do
		merged = false
		for i = #boxes, 2, -1 do
			local a = boxes[i]
			for j = 1, i - 1 do
				local b = boxes[j]
				if a[1] == b[1] and a[2] <= b[5] and b[2] <= a[5] and a[4] <= b[7] and b[4] <= a[7] then
					for k = 2, 4 do
						b[k] = math.min(a[k], b[k])
						b[k + 3] = math.max(a[k + 3], b[k + 3])
					end
					table.remove(boxes, i)
					merged = true
					break
				end
			end
		end
	end
	local regions: { Types.ChangedRegion } = {}
	for _, box in boxes do
		table.insert(regions, {
			Floor = Storage.GetFloorName(n, box[1]),
			Min = vector.create(box[2], box[3], box[4]) :: any, -- a vector is a Vector3 on Roblox
			Max = vector.create(box[5], box[6], box[7]) :: any,
		})
	end
	return regions
end

-- Applies every pending change; see the class docs. Errors leave `s` untouched. Returns the new
-- state and the changed regions.
local function apply(s: State): (State, { Types.ChangedRegion })
	local plan = prepare(s)
	local dirty = plan.Dirty

	-- The fresh state: static data shared, clean tiles copied as ranges and renumbered in one
	-- pass, rebuilt tiles written from scratch.
	local n = Storage.ShellFrom(s)
	Storage.SetTriangleCount(n, plan.FinalTriangleCount)
	for tile = 1, Storage.TileCount(s) do
		if not dirty[tile] then
			local first, count = Storage.GetTileRange(s, tile)
			local to = plan.NewFirst[tile]
			Storage.CopyTriangleRange(n, to, s, first, count)
			Storage.SetTileRange(n, tile, to, count)
			if count > 0 then
				Storage.RemapTriangles(n, to, to + count - 1, plan.Moved, plan.SegStart, plan.SegDelta)
			end
		end
	end
	for _, tile in plan.DirtyList do
		local out = plan.Scratch[tile]
		local first = plan.NewFirst[tile]
		local floor = Storage.GetTileFloor(s, tile)
		local verts, nbrs = out.Verts, out.Neighbors
		for i = 1, #out.Areas do
			local t = first + i - 1
			Storage.SetTriangle(n, t, verts[3 * i - 2], verts[3 * i - 1], verts[3 * i])
			for e = 1, 3 do
				local m = nbrs[3 * (i - 1) + e]
				Storage.SetNeighbor(n, t, e, if m == 0 then 0 else first + m - 1)
				Storage.SetCornerWidth(n, t, e, 0)
				Storage.SetPortalWidth(n, t, e, 0)
			end
			Storage.SetTriangleFloor(n, t, floor)
			Storage.SetTriangleArea(n, t, out.Areas[i])
			Storage.SetTriangleTile(n, t, tile)
		end
		Storage.SetTileRange(n, tile, first, #out.Areas)
	end

	-- Vertices: moved ones down, new ones into their slots, the array cut to size. Kept vertices
	-- of the rebuilt tiles lose their wall flags; Clearance.Refresh sets them again.
	for v, to in plan.Moved do
		Storage.SetVertex(n, to, Storage.GetVertex(s, v))
		Storage.SetWallVertex(n, to, Storage.IsWallVertex(s, v))
	end
	for k, v in plan.NewSlot do
		Storage.SetVertex(n, v, plan.NewVerts[k])
		Storage.SetWallVertex(n, v, false)
	end
	for v in plan.OldDirtyVerts do
		if not plan.Freed[v] then
			Storage.SetWallVertex(n, plan.Moved[v] or v, false)
		end
	end
	Storage.SetVertexCount(n, plan.FinalVertexCount)

	-- Cross-tile neighbours: the open edges of the rebuilt tiles and their neighbours meet.
	local open: { [number]: number } = {}
	local function collect(tile: number)
		local first, count = Storage.GetTileRange(n, tile)
		for t = first, first + count - 1 do
			local ids = { Storage.GetTriangle(n, t) }
			for e = 1, 3 do
				if Storage.GetNeighbor(n, t, e) == 0 then
					open[ids[e % 3 + 1] * EDGE_KEY + ids[(e + 1) % 3 + 1]] = t * 4 + e
				end
			end
		end
	end
	for _, tile in plan.DirtyList do
		collect(tile)
	end
	for _, tile in plan.NearList do
		collect(tile)
	end
	Internal.LinkOpenEdges(n, open)

	-- Seams: clean pieces renumbered, rebuilt ones from scratch.
	for piece = 1, Storage.PieceCount(s) do
		local seam, tri, edge = Storage.GetPiece(s, piece)
		local to = remapTriangle(plan, tri)
		if to ~= 0 then
			Storage.InsertPiece(n, seam, to, edge)
		end
	end
	for _, tile in plan.DirtyList do
		local pieces = plan.Scratch[tile].Pieces
		for k = 1, #pieces, 3 do
			Storage.InsertPiece(n, pieces[k], plan.NewFirst[tile] + pieces[k + 1] - 1, pieces[k + 2])
		end
	end
	-- Links, re-snapped onto the new triangles (an end under an obstacle drops out for now).
	local linkTiles: { [number]: boolean } = {}
	for id = 1, Storage.LinkCount(s) do
		local oldFrom, from, oldTo, to, cost, area, label, both, enabled = Storage.GetLink(s, id)
		for _, t in { oldFrom, oldTo } do
			if t ~= 0 then
				linkTiles[Storage.GetTriangleTile(s, t)] = true
			end
		end
		local fromTri, fromAt = Snap.Snap(n, from, LINK_EXTENTS, {})
		local toTri, toAt = Snap.Snap(n, to, LINK_EXTENTS, {})
		-- An end the snap moved in plan is under an obstacle (near its edge): it drops out too,
		-- rather than keep a point off its triangle. (The tolerance only absorbs rounding.)
		if fromAt == nil or (fromAt.X - from.X) ^ 2 + (fromAt.Z - from.Z) ^ 2 > 1e-12 then
			fromTri = 0
		end
		if toAt == nil or (toAt.X - to.X) ^ 2 + (toAt.Z - to.Z) ^ 2 > 1e-12 then
			toTri = 0
		end
		Storage.InsertLink(n, fromTri, from, toTri, to, cost, area, label, both)
		Storage.SetLinkFlag(n, id, enabled)
		for _, t in { fromTri, toTri } do
			if t ~= 0 then
				linkTiles[Storage.GetTriangleTile(n, t)] = true
			end
		end
	end
	Internal.Connect(n)
	-- Obstacles: the pending changes committed. A removed obstacle's record is dropped (its id
	-- stays used: the next id carries over).
	for slot = 1, Storage.ObstacleCount(s) do
		local id, floor, state, xs, zs = Storage.GetObstacleRecord(s, slot)
		if state ~= Storage.OBSTACLE_PENDING_REMOVE then
			Storage.InsertObstacleRecord(n, floor, xs, zs, id)
			Storage.SetObstacleState(n, Storage.ObstacleCount(n), Storage.OBSTACLE_ACTIVE)
		end
	end
	Storage.SetObstacleNextId(n, Storage.GetObstacleNextId(s))

	-- Clearance. A rebuilt triangle with the same three grid points as an old one is the same
	-- triangle: it keeps its widths (corners matched by vertex). New triangles, and any within
	-- their own reach of a changed wall, are recomputed by Clearance.Refresh.
	local old: { [string]: { number } } = {}
	for _, tile in plan.DirtyList do
		local first, count = Storage.GetTileRange(s, tile)
		for t = first, first + count - 1 do
			local key, rotation = triangleKey(s, t)
			local w = { rotation }
			for k = 1, 3 do
				w[1 + k] = Storage.GetCornerWidth(s, t, k)
				w[4 + k] = Storage.GetPortalWidth(s, t, k)
			end
			old[key] = w
		end
	end
	local recompute: { [number]: boolean } = {}
	for _, tile in plan.DirtyList do
		local first, count = Storage.GetTileRange(n, tile)
		for t = first, first + count - 1 do
			local key, rotation = triangleKey(n, t)
			local w = old[key]
			if w == nil then
				recompute[t] = true
				continue
			end
			-- Vertex k of t is vertex ((k - rotation + oldRotation - 1) mod 3) + 1 of the old one.
			for k = 1, 3 do
				local ok = (k - rotation + w[1] - 1) % 3 + 1
				Storage.SetCornerWidth(n, t, k, w[1 + ok])
				Storage.SetPortalWidth(n, t, k, w[4 + ok])
			end
		end
	end
	local changedTiles = Clearance.Refresh(s, n, plan.DirtyList, plan.NearList, recompute)
	for tile in dirty do
		changedTiles[tile] = true
	end

	for tile in changedTiles do
		Storage.BumpTileStamp(n, tile)
	end
	for tile in linkTiles do
		if not changedTiles[tile] then
			Storage.BumpTileStamp(n, tile)
		end
	end
	return n, changedRegions(s, n, plan, recompute)
end

--[=[
	@within NavMeshTiles
	Applies every pending obstacle change (see the class docs). Atomic: on an error the mesh is
	unchanged, the pending records are rolled back, and the error is raised again.
]=]
function Tiles.Update(s: State): { Types.ChangedRegion }
	local pending = false
	for slot = 1, Storage.ObstacleCount(s) do
		if Storage.GetObstacleState(s, slot) ~= Storage.OBSTACLE_ACTIVE then
			pending = true
			break
		end
	end
	if not pending then
		return {}
	end
	local ok, result, regions = pcall(apply, s)
	if not ok then
		-- Roll back: pending adds go (their ids stay used), pending removals stay active.
		for slot = Storage.ObstacleCount(s), 1, -1 do
			local state = Storage.GetObstacleState(s, slot)
			if state == Storage.OBSTACLE_PENDING_ADD then
				Storage.RemoveObstacleRecord(s, slot)
			elseif state == Storage.OBSTACLE_PENDING_REMOVE then
				Storage.SetObstacleState(s, slot, Storage.OBSTACLE_ACTIVE)
			end
		end
		error(result, 0)
	end
	-- Swap the fresh state in, keeping the caller's table.
	table.clear(s)
	for key, value in result :: any do
		(s :: any)[key] = value
	end
	return regions
end

return Tiles
