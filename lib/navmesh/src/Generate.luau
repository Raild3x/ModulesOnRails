--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- October 1, 2026
--[=[
	@class NavMeshGenerate
	@private

	`NavMesh.GenerateLinks` (ticket 30, part 2): drop and jump links read off a built mesh. Pure:
	it reads the mesh and returns `LinkDesc`s.

	1. **Samples:** every wall edge, every `Spacing / 4` studs.
	2. **March:** from each sample, straight out from the wall, first `PROBE` studs, then every
	   `STEP` studs up to `MaxJumpDistance`. Each column is tested against every floor's
	   triangles. The first column holding a surface between `MaxDrop` below and `MaxJumpUp`
	   above the sample is the landing (the highest such surface there).
	   - A column inside the sample's own floor's walkable rings with no triangle of it is an
	     obstacle (a wall, a railing): the march stops there with no link. That is the walled-edge
	     rule, so an interior wall never drops through the ceiling.
	3. **Ends:** both ends are pushed `Clearance` off the walls (`Queries.Push`) and must then
	   admit it (`Queries.DistanceToWall`).
	   - A landing lower than the sample within `Clearance` of the wall is a one-way `Drop`.
	   - Anything else is a `Jump`, two-way when the climb back is within both `MaxJumpUp` and
	     `MaxDrop`.
	4. **Dedupe and detour:** the candidates are kept greedily, in triangle and edge order (so the
	   same mesh gives the same list): a candidate whose ends are both within `Spacing` of a kept
	   link's between the same floors is dropped, and so is one that walking already serves: a
	   walk (`FindPath`'s `Length` at radius `Clearance`) shorter than `DetourFactor` times the
	   link.
]=]

local Queries = require("./Queries")
local Snap = require("./Snap")
local Storage = require("./Storage")
local Types = require("./Types")

type LinkDesc = Types.LinkDesc
type GenerateLinksOptions = Types.GenerateLinksOptions

local PROBE = 0.05 -- the first column, just past the wall: past snap rounding's pixel, inside any real wall
local STEP = 0.5 -- the march step, so a gap is measured to within this
local MARGIN = 0.01 -- a column this near a ring's edge is not inside it (snap rounding moves edges a pixel)
local FIT = 1e-3 -- slack on "both ends admit Clearance", for the push's rounding
local WALKABLE_GROUP = 1 -- Build's GROUP_WALKABLE: a floor's walkable rings in its sources
local NO_COSTS = {}

local OPTIONS = { Labels = true }
-- The number options: name, default, lowest.
local NUMBERS = {
	{ "Spacing", 4, 0 },
	{ "MaxDrop", 10, 0 },
	{ "MaxJumpDistance", 6, 0 },
	{ "MaxJumpUp", 3, 0 },
	{ "Clearance", 1, 0 },
	{ "Area", 1, 1 },
	{ "DetourFactor", 2, 0 },
}
for _, entry in NUMBERS do
	OPTIONS[entry[1] :: string] = true
end

type Candidate = {
	From: vector,
	To: vector,
	FromT: number,
	ToT: number,
	FromFloor: number,
	ToFloor: number,
	Label: string,
	Both: boolean,
}

type Ring = { X: { number }, Z: { number } }

local Generate = {}

-- Whether (x, z) is inside one of `rings` (studs) by more than MARGIN.
local function inside(rings: { Ring }, x: number, z: number): boolean
	for _, ring in rings do
		local xs, zs = ring.X, ring.Z
		local odd, near = false, false
		local j = #xs
		for i = 1, #xs do
			local ax, az, bx, bz = xs[j], zs[j], xs[i], zs[i]
			if (az > z) ~= (bz > z) and x < ax + (z - az) / (bz - az) * (bx - ax) then
				odd = not odd
			end
			local dx, dz = bx - ax, bz - az
			local u = math.clamp(((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz), 0, 1)
			if (ax + u * dx - x) ^ 2 + (az + u * dz - z) ^ 2 <= MARGIN * MARGIN then
				near = true
			end
			j = i
		end
		if odd and not near then
			return true
		end
	end
	return false
end

-- The triangle of `floor` holding column (x, z), and the surface point there; or 0, nil.
local function surfaceAt(mesh: Storage.State, floor: number, x: number, z: number): (number, vector?)
	local p = vector.create(x, 0, z)
	for _, tile in Snap.TilesIn(mesh, floor, x, z, x, z) do
		local first, count = Storage.GetTileRange(mesh, tile)
		for t = first, first + count - 1 do
			local q = Snap.ClosestOnTriangle(mesh, t, p)
			if q.X == p.X and q.Z == p.Z then -- inside (or on) t: compared in f32, as vectors hold it
				return t, q
			end
		end
	end
	return 0, nil
end

-- Whether `c` repeats kept link `k`: both ends within `spacing`, between the same floors (either
-- way round when `k` is two-way).
local function repeats(c: Candidate, k: Candidate, spacing: number): boolean
	if
		c.FromFloor == k.FromFloor
		and c.ToFloor == k.ToFloor
		and vector.magnitude(c.From - k.From) < spacing
		and vector.magnitude(c.To - k.To) < spacing
	then
		return true
	end
	return k.Both
		and c.FromFloor == k.ToFloor
		and c.ToFloor == k.FromFloor
		and vector.magnitude(c.From - k.To) < spacing
		and vector.magnitude(c.To - k.From) < spacing
end

--[=[
	@within NavMeshGenerate
	`NavMesh.GenerateLinks`: validates `options`, then returns the links (see the class doc).
	`walk` is the length of the walk between two surface points at a radius (`FindPath`'s
	`Length`), or `math.huge` when there is none. Errors are raised at level 3, the wrapper's caller.
]=]
function Generate.Links(
	mesh: Storage.State,
	options: GenerateLinksOptions?,
	walk: (from: vector, to: vector, radius: number) -> number
): { LinkDesc }
	local o: any = options or {}
	if type(o) ~= "table" then
		error("NavMesh.GenerateLinks: options must be a table", 3)
	end
	for key in o do
		if not OPTIONS[key] then
			error(
				`NavMesh.GenerateLinks: unknown option '{key}' (known: Spacing, MaxDrop, MaxJumpDistance, MaxJumpUp, Clearance, Area, Labels, DetourFactor)`,
				3
			)
		end
	end
	local values: { [string]: number } = {}
	for _, entry in NUMBERS do
		local key, value = entry[1] :: string, o[entry[1]]
		if value == nil then
			value = entry[2]
		elseif type(value) ~= "number" or not (value >= entry[3] and value < math.huge) then
			error(`NavMesh.GenerateLinks: {key} must be a number >= {entry[3]}`, 3)
		end
		values[key] = value
	end
	local spacing, maxDrop, maxJump, maxUp = values.Spacing, values.MaxDrop, values.MaxJumpDistance, values.MaxJumpUp
	local clearance, area, detour = values.Clearance, values.Area, values.DetourFactor
	if spacing == 0 then
		error("NavMesh.GenerateLinks: Spacing must be a number > 0", 3)
	end
	if area % 1 ~= 0 then
		error("NavMesh.GenerateLinks: Area must be a whole number >= 1", 3)
	end
	local cap = Storage.GetMaxAgentRadius(mesh)
	if cap > 0 and clearance > cap then
		error(`NavMesh.GenerateLinks: Clearance {clearance} is above the mesh's MaxAgentRadius {cap}`, 3)
	end
	local labels = o.Labels or {}
	if
		type(labels) ~= "table"
		or (labels.Drop ~= nil and type(labels.Drop) ~= "string")
		or (labels.Jump ~= nil and type(labels.Jump) ~= "string")
	then
		error("NavMesh.GenerateLinks: Labels must be a table { Drop: string?, Jump: string? }", 3)
	end
	local dropLabel, jumpLabel = labels.Drop or "Drop", labels.Jump or "Jump"

	-- Each floor's walkable rings, in studs.
	local floors = Storage.FloorCount(mesh)
	local footprints: { { Ring } } = {}
	for f = 1, floors do
		local _, _, _, rings, groups = Storage.GetFloorSources(mesh, f)
		local walkable = {}
		for i, ring in rings do
			if groups[i] == WALKABLE_GROUP then
				local xs, zs = {}, {}
				for k, x in ring.X do
					xs[k], zs[k] = x / 256, ring.Z[k] / 256
				end
				table.insert(walkable, { X = xs, Z = zs })
			end
		end
		footprints[f] = walkable
	end

	local candidates: { Candidate } = {}
	-- The link off sample `s` (on wall edge of triangle `t`, floor `floor`) along outward `n`.
	local function march(t: number, floor: number, s: vector, n: vector)
		local lo, hi = s.Y - maxDrop, s.Y + maxUp
		local d = PROBE
		while d <= math.max(maxJump, PROBE) do
			local x, z = s.X + n.X * d, s.Z + n.Z * d
			local landT, landP, landFloor = 0, nil :: vector?, 0
			for f = 1, floors do
				local ft, fp = surfaceAt(mesh, f, x, z)
				if fp == nil then
					if f == floor and inside(footprints[f], x, z) then
						return -- this floor's own obstacle: a wall, not a ledge
					end
				elseif fp.Y >= lo and fp.Y <= hi and (landP == nil or fp.Y > landP.Y) then
					landT, landP, landFloor = ft, fp, f
				end
			end
			if landP then
				-- Land a radius further out when that floor is there: a drop's straight down.
				local farT, farP = surfaceAt(mesh, landFloor, x + n.X * clearance, z + n.Z * clearance)
				local fromP, fromT = Queries.Push(mesh, t, s, clearance, NO_COSTS)
				local toP, toT = Queries.Push(mesh, if farP then farT else landT, farP or landP, clearance, NO_COSTS)
				if
					clearance > 0
					and (
						Queries.DistanceToWall(mesh, fromT, fromP, clearance, NO_COSTS) < clearance - FIT
						or Queries.DistanceToWall(mesh, toT, toP, clearance, NO_COSTS) < clearance - FIT
					)
				then
					return -- an end too narrow for the agent
				end
				local drop = landP.Y < s.Y and d <= math.max(clearance, PROBE)
				local rise = math.abs(landP.Y - s.Y)
				table.insert(candidates, {
					From = fromP,
					To = toP,
					FromT = fromT,
					ToT = toT,
					FromFloor = floor,
					ToFloor = landFloor,
					Label = if drop then dropLabel else jumpLabel,
					Both = not drop and rise <= maxUp and rise <= maxDrop,
				})
				return
			end
			d = if d == PROBE then STEP else d + STEP
		end
	end

	local step = spacing / 4
	for t = 1, Storage.TriangleCount(mesh) do
		local verts = { Storage.GetTriangle(mesh, t) }
		for e = 1, 3 do
			if not Storage.IsWallEdge(mesh, t, e) then
				continue
			end
			local u, w = Storage.GetVertex(mesh, verts[e % 3 + 1]), Storage.GetVertex(mesh, verts[(e + 1) % 3 + 1])
			local length = math.sqrt((w.X - u.X) ^ 2 + (w.Z - u.Z) ^ 2)
			-- Out of a CCW triangle: the interior is on the left of u -> w.
			local n = vector.create((w.Z - u.Z) / length, 0, (u.X - w.X) / length)
			local count = math.ceil(length / step)
			for i = 1, count do
				march(t, Storage.GetTriangleFloor(mesh, t), u + (w - u) * ((i - 0.5) / count), n)
			end
		end
	end

	local kept: { Candidate } = {}
	local out: { LinkDesc } = {}
	-- ponytail: O(links^2) repeat test and one search per survivor; a spatial hash and a
	-- cost-bounded search if huge maps make this slow.
	for _, c in candidates do
		local seen = false
		for _, k in kept do
			if repeats(c, k, spacing) then
				seen = true
				break
			end
		end
		if seen then
			continue
		end
		if walk(c.From, c.To, clearance) < detour * vector.magnitude(c.To - c.From) then
			continue
		end
		table.insert(kept, c)
		table.insert(out, {
			From = c.From :: any, -- a vector is a Vector3 on Roblox
			To = c.To :: any,
			Bidirectional = c.Both,
			Area = area,
			Label = c.Label,
		})
	end
	return out
end

return Generate
