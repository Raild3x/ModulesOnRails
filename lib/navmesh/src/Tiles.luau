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

	**Rebuild:**
	- A dirty tile with no active obstacle is rebuilt from its baseline, the exact triangulation
	  input Build gave it, with no re-snap work. So add-then-remove reproduces a fresh Build
	  (SR14); re-snapping an obstacle-free baseline also leaves it unchanged, since snap
	  rounding is idempotent on snapped input.
	- The other dirty tiles of a floor are snap-rounded together from their baselines plus the
	  active obstacles over them (local re-snap, ruled 2026-09-26). Each tile gets its own
	  fragments, the obstacle chains clipped to it, and every snapped vertex on its border.
	- Every dirty tile is triangulated by Build's own `TriangulateTile`.

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
	- The state is swapped in only when all of that succeeded. On an error the mesh is
	  untouched, the pending records are rolled back, and the error is raised again.

	**Cost:** the dirty tiles' re-snap, triangulation and clearance, plus an O(T) range copy and
	renumbering pass (buffer operations, about 0.1 ms per 1,000 triangles) and O(tiles) loops.
]=]

local Build = require("./Build")
local Clearance = require("./Clearance")
local Quantize = require("./Quantize")
local Snap = require("./Snap")
local Storage = require("./Storage")
local Types = require("./Types")

local Internal = Build.Internal
local GRID = Internal.GRID
local PointKey = Internal.PointKey
local EDGE_KEY = Internal.EDGE_KEY
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

-- Whether a tile's rectangle grown by one pixel overlaps the box.
local function touches(s: State, tile: number, bx0: number, bz0: number, bx1: number, bz1: number): boolean
	local x0, z0, x1, z1 = tileRect(s, tile)
	return x0 - 1 <= bx1 and bx0 <= x1 + 1 and z0 - 1 <= bz1 and bz0 <= z1 + 1
end

type Obstacle = { Id: number, Floor: number, X: { number }, Z: { number }, Box: { number } }

-- The triangulation input for each dirty tile of one floor that has active obstacles over it:
-- its baseline and those obstacles snap-rounded together (one re-snap per floor).
local function reSnap(
	s: State,
	tiles: { number },
	obstacles: { Obstacle },
	tileSize: number
): { [number]: { Coords: { number }, Edges: { number }, Groups: { number }, Seams: { number } } }
	local coords, edges = {}, {}
	local edgeTile, edgeGroup, edgeSeam = {}, {}, {}
	local obstacleEdges: { [number]: { number } } = {} -- obstacle index -> its input edge ids, in order
	for _, tile in tiles do
		local tc, te, tg, ts = Storage.GetTileSources(s, tile)
		local offset = #coords // 2
		table.move(tc, 1, #tc, #coords + 1, coords)
		for k = 1, #tg do
			table.insert(edges, offset + te[2 * k - 1])
			table.insert(edges, offset + te[2 * k])
			local id = #edges // 2
			edgeTile[id], edgeGroup[id], edgeSeam[id] = tile, tg[k], ts[k]
		end
	end
	for index, obstacle in obstacles do
		local offset = #coords // 2
		local n = #obstacle.X
		local ids = {}
		for i = 1, n do
			table.insert(coords, obstacle.X[i])
			table.insert(coords, obstacle.Z[i])
		end
		for i = 1, n do
			table.insert(edges, offset + i)
			table.insert(edges, offset + i % n + 1)
			table.insert(ids, #edges // 2)
		end
		obstacleEdges[index] = ids
	end
	-- The floor's tile lines over everything above, as in Build: an obstacle can also cross a
	-- line beside a clean tile, and clipping needs every crossing at a snapped vertex.
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, #coords, 2 do
		minX, maxX = math.min(minX, coords[i]), math.max(maxX, coords[i])
		minZ, maxZ = math.min(minZ, coords[i + 1]), math.max(maxZ, coords[i + 1])
	end
	local ix0, ix1 = math.floor(minX / tileSize), math.ceil(maxX / tileSize)
	local iz0, iz1 = math.floor(minZ / tileSize), math.ceil(maxZ / tileSize)
	local function addLine(ax: number, az: number, bx: number, bz: number)
		table.move({ ax, az, bx, bz }, 1, 4, #coords + 1, coords)
		table.insert(edges, #coords // 2 - 1)
		table.insert(edges, #coords // 2)
	end
	for i = ix0, ix1 do
		addLine(i * tileSize, iz0 * tileSize, i * tileSize, iz1 * tileSize)
	end
	for j = iz0, iz1 do
		addLine(ix0 * tileSize, j * tileSize, ix1 * tileSize, j * tileSize)
	end

	local snapped, fragments, source = Quantize.SnapRound(coords, edges)
	local inputs = {}
	for _, tile in tiles do
		inputs[tile] = { Coords = {}, Edges = {}, Groups = {}, Seams = {} }
	end
	local function addEdge(input: any, ax: number, az: number, bx: number, bz: number, group: number, seam: number)
		local c = input.Coords
		table.move({ ax, az, bx, bz }, 1, 4, #c + 1, c)
		table.insert(input.Edges, #c // 2 - 1)
		table.insert(input.Edges, #c // 2)
		table.insert(input.Groups, group)
		table.insert(input.Seams, seam)
	end
	-- Each baseline edge's fragments go back to its own tile, with its group and seam.
	local fragFirst, fragLast = {}, {}
	for f, k in source do
		if fragFirst[k] == nil then
			fragFirst[k] = f
		end
		fragLast[k] = f
		local tile = edgeTile[k]
		if tile then
			local a, b = fragments[2 * f - 1], fragments[2 * f]
			addEdge(
				inputs[tile],
				snapped[2 * a - 1],
				snapped[2 * a],
				snapped[2 * b - 1],
				snapped[2 * b],
				edgeGroup[k],
				edgeSeam[k]
			)
		end
	end
	-- Each obstacle as its snapped closed chain, clipped to every dirty tile.
	for index, obstacle in obstacles do
		local xs, zs = {}, {}
		for _, k in obstacleEdges[index] do
			if fragFirst[k] == nil then
				continue -- a zero-length edge
			end
			for f = fragFirst[k], fragLast[k] do
				local v = fragments[2 * f - 1]
				table.insert(xs, snapped[2 * v - 1])
				table.insert(zs, snapped[2 * v])
			end
		end
		for _, tile in tiles do
			local x0, z0, x1, z1 = tileRect(s, tile)
			local cx, cz = Internal.ClipToRect(xs, zs, x0, z0, x1, z1)
			if cx then
				local n = #cx
				for i = 1, n do
					local j = i % n + 1
					addEdge(inputs[tile], cx[i], cz[i], cx[j], cz[j], Internal.GROUP_OBSTACLE, 0)
				end
			end
		end
	end
	-- Every snapped vertex on a tile's border, so neighbours split shared borders alike.
	for _, tile in tiles do
		local x0, z0, x1, z1 = tileRect(s, tile)
		local c = inputs[tile].Coords
		for v = 1, #snapped // 2 do
			local x, z = snapped[2 * v - 1], snapped[2 * v]
			if x >= x0 and x <= x1 and z >= z0 and z <= z1 and (x == x0 or x == x1 or z == z0 or z == z1) then
				table.insert(c, x)
				table.insert(c, z)
			end
		end
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

	-- Dirty tiles through the tile hash (O(dirty), not O(tiles)), then their clean neighbours:
	-- the tiles whose closed rectangle touches a dirty one.
	local dirty: { [number]: boolean } = {}
	local dirtyByFloor: { [number]: { number } } = {}
	for floor, boxes in pendingFloors do
		for _, box in boxes do
			local x0, z0 = (box[1] - 1) / GRID, (box[2] - 1) / GRID
			local x1, z1 = (box[3] + 1) / GRID, (box[4] + 1) / GRID
			for _, tile in Snap.TilesIn(s, floor, x0, z0, x1, z1) do
				if not dirty[tile] and touches(s, tile, box[1], box[2], box[3], box[4]) then
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
		local tileSize, defaultArea, areaIds, rings = Storage.GetFloorSources(s, floor)
		local surfaces = {}
		for i, ring in rings do
			surfaces[i] = Internal.MakeSurface(ring)
		end
		local floorData = {
			Context = `floor '{Storage.GetFloorName(s, floor)}'`,
			Surfaces = surfaces,
			AreaIds = areaIds,
			DefaultArea = defaultArea,
			Heights = floorHeights[floor],
			HeightFrom = {},
		}
		-- Tiles with an active obstacle over them are re-snapped together; the rest use their
		-- baseline verbatim.
		local floorActive: { Obstacle } = active[floor] or {}
		local covered, overs = {}, {}
		for _, tile in tiles do
			local x0, z0, x1, z1 = tileRect(s, tile)
			for _, obstacle in floorActive do
				local b = obstacle.Box
				if x0 - 1 <= b[3] and b[1] <= x1 + 1 and z0 - 1 <= b[4] and b[2] <= z1 + 1 then
					table.insert(covered, tile)
					break
				end
			end
		end
		for _, obstacle in floorActive do
			for _, tile in covered do
				if touches(s, tile, obstacle.Box[1], obstacle.Box[2], obstacle.Box[3], obstacle.Box[4]) then
					table.insert(overs, obstacle)
					break
				end
			end
		end
		local snappedInputs = if #covered > 0 then reSnap(s, covered, overs, tileSize) else {}
		for _, tile in tiles do
			local input = snappedInputs[tile]
			if input == nil then
				local tc, te, tg, ts = Storage.GetTileSources(s, tile)
				input = { Coords = tc, Edges = te, Groups = tg, Seams = ts }
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

-- Applies every pending change; see the class docs. Errors leave `s` untouched.
local function apply(s: State): State
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
		Storage.ClearTriangleFlags(n, first, #out.Areas)
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

	for tile in changedTiles do
		Storage.BumpTileStamp(n, tile)
	end
	for tile in linkTiles do
		if not changedTiles[tile] then
			Storage.BumpTileStamp(n, tile)
		end
	end
	return n
end

--[=[
	@within NavMeshTiles
	Applies every pending obstacle change (see the class docs). Atomic: on an error the mesh is
	unchanged, the pending records are rolled back, and the error is raised again.
]=]
function Tiles.Update(s: State)
	local pending = false
	for slot = 1, Storage.ObstacleCount(s) do
		if Storage.GetObstacleState(s, slot) ~= Storage.OBSTACLE_ACTIVE then
			pending = true
			break
		end
	end
	if not pending then
		return
	end
	local ok, result = pcall(apply, s)
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
end

return Tiles
