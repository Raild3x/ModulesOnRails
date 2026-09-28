--!strict
-- Bench variant (ticket 22 baseline): lib/navmesh/src/Tiles.luau as of c22136d, the Update that
-- builds a whole fresh state, with its Clearance. Requires point at the live modules.
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

	**Commit (atomic, SR13/SR14):**
	- A fresh state is built: clean tiles are copied and renumbered, dirty tiles take their new
	  triangles, and vertices are re-interned per floor by grid point. Nothing is left behind,
	  so toggling a door never grows memory, and ids are only stable until the next Update.
	- Seam portals and links are rebuilt (links re-snap onto the new triangles).
	- Clearance is recomputed for the dirty tiles and every triangle within its own reach r*
	  of them (ruling U-a); the rest is copied.
	- Stamps are bumped for every tile whose triangles or widths changed, and for the tiles at
	  the ends of every link.
	- The state is swapped in only when all of that succeeded. On an error the mesh is
	  untouched, the pending records are rolled back, and the error is raised again.
]=]

local Build = require("../../../../lib/navmesh/src/Build")
local Clearance = require("./Clearance")
local Quantize = require("../../../../lib/navmesh/src/Quantize")
local Snap = require("../../../../lib/navmesh/src/Snap")
local Storage = require("../../../../lib/navmesh/src/Storage")
local Types = require("../../../../lib/navmesh/src/Types")

local Internal = Build.Internal
local GRID = Internal.GRID
local PointKey = Internal.PointKey

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

-- A lower bound on the distance in plan (studs) from triangle t to the box: the gap between
-- the box and the triangle's own bounding box. Never more than the true distance, so a
-- triangle whose width might change is never skipped.
local function distanceToBox(s: State, t: number, x0: number, z0: number, x1: number, z1: number): number
	local a, b, c = Storage.GetTriangle(s, t)
	local pa, pb, pc = Storage.GetVertex(s, a), Storage.GetVertex(s, b), Storage.GetVertex(s, c)
	local dx = math.max(x0 - math.max(pa.X, pb.X, pc.X), 0, math.min(pa.X, pb.X, pc.X) - x1)
	local dz = math.max(z0 - math.max(pa.Z, pb.Z, pc.Z), 0, math.min(pa.Z, pb.Z, pc.Z) - z1)
	return math.sqrt(dx * dx + dz * dz)
end

-- Applies every pending change; see the class docs. Errors leave `s` untouched.
local function apply(s: State): State
	-- Pending changes and the obstacles active after this commit.
	local pendingFloors: { [number]: { { number } } } = {} -- floor -> boxes of changed obstacles
	local active: { [number]: { Obstacle } } = {} -- floor -> obstacles active after commit
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

	-- Dirty tiles.
	local dirty: { [number]: boolean } = {}
	local dirtyByFloor: { [number]: { number } } = {}
	for tile = 1, Storage.TileCount(s) do
		local floor = Storage.GetTileFloor(s, tile)
		local boxes: { { number } } = pendingFloors[floor] or {}
		for _, box in boxes do
			if touches(s, tile, box[1], box[2], box[3], box[4]) then
				dirty[tile] = true
				local list = dirtyByFloor[floor] or {}
				dirtyByFloor[floor] = list
				table.insert(list, tile)
				break
			end
		end
	end

	-- New triangles for each dirty tile.
	local rebuilt: { [number]: { any } } = {}
	local rebuiltInput: { [number]: any } = {}
	local floorHeights: { [number]: { [number]: number } } = {}
	for floor, tiles in dirtyByFloor do
		local tileSize, defaultArea, areaIds, rings = Storage.GetFloorSources(s, floor)
		local surfaces = {}
		for i, ring in rings do
			surfaces[i] = Internal.MakeSurface(ring)
		end
		-- Every current vertex height of the floor, so rebuilt tiles must agree with them.
		local heights, from = {}, {}
		for t = 1, Storage.TriangleCount(s) do
			if Storage.GetTriangleFloor(s, t) == floor then
				for _, v in { Storage.GetTriangle(s, t) } do
					local p = Storage.GetVertex(s, v)
					heights[PointKey(math.round(p.X * GRID), math.round(p.Z * GRID))] = p.Y
				end
			end
		end
		floorHeights[floor] = heights
		local floorData = {
			Context = `floor '{Storage.GetFloorName(s, floor)}'`,
			Surfaces = surfaces,
			AreaIds = areaIds,
			DefaultArea = defaultArea,
			Heights = heights,
			HeightFrom = from,
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

	-- The fresh state: every tile in order, clean ones copied, dirty ones rebuilt.
	local n = Storage.New()
	for f = 1, Storage.FloorCount(s) do
		Storage.InsertFloor(n, Storage.GetFloorName(s, f))
		local tileSize, defaultArea, areaIds, rings = Storage.GetFloorSources(s, f)
		Storage.SetFloorSources(n, f, tileSize, defaultArea, areaIds, rings)
	end
	local remap: { number } = {} -- old triangle -> new triangle (clean tiles only)
	local meshVertex: { [number]: { [number]: number } } = {}
	local openEdges: { [number]: { [number]: number } } = {}
	for tile = 1, Storage.TileCount(s) do
		local floor = Storage.GetTileFloor(s, tile)
		local x0, z0, x1, z1 = Storage.GetTileBounds(s, tile)
		assert(Storage.InsertTile(n, floor, x0, z0, x1, z1) == tile, "tile ids must survive a rebuild")
		local tc, te, tg, ts = Storage.GetTileSources(s, tile)
		Storage.SetTileSources(n, tile, tc, te, tg, ts)
		Storage.SetTileStamp(n, tile, Storage.GetTileStamp(s, tile))
		meshVertex[floor] = meshVertex[floor] or {}
		openEdges[floor] = openEdges[floor] or {}
		local context = `floor '{Storage.GetFloorName(s, floor)}'`
		if dirty[tile] then
			local input = rebuiltInput[tile]
			Internal.CopyOut(
				n,
				context,
				tile,
				rebuilt[tile],
				floorHeights[floor],
				meshVertex[floor],
				openEdges[floor],
				Internal.SeamFragments(input.Coords, input.Edges, input.Seams)
			)
			continue
		end
		-- A clean tile: its triangles as they are, with in-tile neighbours kept.
		local first, count = Storage.GetTileRange(s, tile)
		local triangles = table.create(count)
		local heights = {}
		for i = 1, count do
			local t = first + i - 1
			local xs, zs, keys = {}, {}, {}
			for k, v in { Storage.GetTriangle(s, t) } do
				local p = Storage.GetVertex(s, v)
				xs[k], zs[k] = math.round(p.X * GRID), math.round(p.Z * GRID)
				keys[k] = PointKey(xs[k], zs[k])
				heights[keys[k]] = p.Y
			end
			local nbrs = {}
			for e = 1, 3 do
				local m = Storage.GetNeighbor(s, t, e)
				nbrs[e] = if m >= first and m < first + count then m - first + 1 else 0
			end
			triangles[i] = { X = xs, Z = zs, Keys = keys, Area = Storage.GetTriangleArea(s, t), Neighbors = nbrs }
		end
		local newFirst = Storage.TriangleCount(n) + 1
		Internal.CopyOut(n, context, tile, triangles, heights, meshVertex[floor], openEdges[floor], {})
		for i = 1, count do
			local old, new = first + i - 1, newFirst + i - 1
			remap[old] = new
			for k = 1, 3 do
				Storage.SetCornerWidth(n, new, k, Storage.GetCornerWidth(s, old, k))
				Storage.SetPortalWidth(n, new, k, Storage.GetPortalWidth(s, old, k))
			end
		end
	end
	for _, edges in openEdges do
		Internal.LinkOpenEdges(n, edges)
	end
	-- Seams: clean tiles keep their pieces (renumbered); dirty ones found theirs in CopyOut.
	for piece = 1, Storage.PieceCount(s) do
		local seam, tri, edge = Storage.GetPiece(s, piece)
		if remap[tri] then
			Storage.InsertPiece(n, seam, remap[tri], edge)
		end
	end
	for seam = 1, Storage.SeamCount(s) do
		Storage.InsertSeam(n, Storage.GetSeam(s, seam))
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
	-- triangle: it keeps its widths like a clean one (corners matched by vertex). Only new
	-- triangles, and old ones within their own reach of a change, are recomputed.
	local function gridKeys(state: State, t: number): { number }
		local keys = {}
		for k, v in { Storage.GetTriangle(state, t) } do
			local p = Storage.GetVertex(state, v)
			keys[k] = PointKey(math.round(p.X * GRID), math.round(p.Z * GRID))
		end
		return keys
	end
	-- A triangle's key: its grid points from the smallest one, in CCW order.
	local function triangleKey(keys: { number }): (string, number)
		local first = if keys[1] < keys[2] and keys[1] < keys[3] then 1 elseif keys[2] < keys[3] then 2 else 3
		return `{keys[first]}:{keys[first % 3 + 1]}:{keys[(first + 1) % 3 + 1]}`, first
	end
	local oldByKey: { [string]: number } = {}
	local oldFirstVertex: { [number]: number } = {}
	for tile in dirty do
		local first, count = Storage.GetTileRange(s, tile)
		for t = first, first + count - 1 do
			local key, rotation = triangleKey(gridKeys(s, t))
			oldByKey[key] = t
			oldFirstVertex[t] = rotation
		end
	end
	local recompute: { [number]: boolean } = {}
	for tile in dirty do
		local first, count = Storage.GetTileRange(n, tile)
		for t = first, first + count - 1 do
			local key, rotation = triangleKey(gridKeys(n, t))
			local old = oldByKey[key]
			if old == nil then
				recompute[t] = true
				continue
			end
			remap[old] = t
			-- Vertex k of t is vertex ((k - rotation + oldRotation - 1) mod 3) + 1 of old.
			for k = 1, 3 do
				local ok = (k - rotation + oldFirstVertex[old] - 1) % 3 + 1
				Storage.SetCornerWidth(n, t, k, Storage.GetCornerWidth(s, old, ok))
				Storage.SetPortalWidth(n, t, k, Storage.GetPortalWidth(s, old, ok))
			end
		end
	end
	-- Walls change only inside the changed obstacles' boxes (plus the pixel margin), so reach
	-- is measured from those, not from the (much larger) dirty tiles.
	local changedTiles: { [number]: boolean } = table.clone(dirty)
	for floor, boxes in pendingFloors do
		for _, box in boxes do
			local bx0, bz0 = (box[1] - 1) / GRID, (box[2] - 1) / GRID
			local bx1, bz1 = (box[3] + 1) / GRID, (box[4] + 1) / GRID
			for old, new in remap do
				if Storage.GetTriangleFloor(s, old) ~= floor or recompute[new] then
					continue
				end
				local reach = 0
				for k = 1, 3 do
					reach = math.max(reach, Storage.GetCornerWidth(s, old, k), Storage.GetPortalWidth(s, old, k))
				end
				if distanceToBox(n, new, bx0, bz0, bx1, bz1) <= reach / 2 then
					recompute[new] = true
					changedTiles[Storage.GetTriangleTile(n, new)] = true
				end
			end
		end
	end
	Clearance.Compute(n, Storage.GetMaxAgentRadius(s), recompute)

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
