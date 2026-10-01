--!strict
-- Authors: Logan Hunt (Raildex)
-- September 28, 2026
--[=[
	@class NavMeshAdapter

	Turns anchored Parts into a `NavMeshDesc`, so a level is authored once, as Parts.

	- Every Part is solid: where it stands inside the agent's height above a floor, its
	  footprint is cut out of that floor (a crate on the ground, the ground under a ramp).
	- A walkable Part's upward faces (no steeper than `MaxSlope`) are walkable. Faces on one
	  plane form one floor, named after the first Part that lands on it; faces of a floor that
	  share an edge become one ring.
	- Where an edge of one floor's face lies on another floor's surface (the foot and top of a
	  ramp), a seam joins them.
	- With `MaxStepHeight`, an edge that lies up to that far above another floor's face (a stair
	  step's riser, a curb) gets a strip floor, 0.25 studs wide and as steep as the rise, seamed to
	  both. Paths climb stairs and curbs; their heights rise over each strip.

	Blocks, wedges and cylinders are supported. The result is plain data: add `Links` and
	`MaxAgentRadius` to it, then pass it to `NavMesh.Build`.
]=]

--[=[
	@within NavMeshAdapter
	@interface AdapterOptions
	.AgentHeight number? -- studs above a floor a Part must stand within to cut it (default 5)
	.MaxSlope number? -- steepest walkable face, in degrees (default 45)
	.CylinderSides number? -- sides of the polygon a cylinder becomes (default 16)
	.WeldTolerance number? -- cracks up to this wide between faces of one floor are closed (default 0.05 studs; 0 turns welding off)
	.MaxStepHeight number? -- floors whose faces meet across a rise up to this many studs are joined by a steep strip floor over the riser (stairs, curbs; default 0: off)
]=]
export type AdapterOptions = {
	AgentHeight: number?,
	MaxSlope: number?,
	CylinderSides: number?,
	WeldTolerance: number?,
	MaxStepHeight: number?,
}

local NavMesh = require("../NavMesh")

-- Heights within this many studs count as the same surface (seam edges). Part data is f32, so a
-- hinge between two turned Parts is only true to about 1e-5 studs: seam edges also use it as
-- their distance tolerance across a face's edge and their shortest length.
local HEIGHT_TOLERANCE = 0.01
-- Faces within this many studs of a floor's plane join that floor. Much tighter than
-- HEIGHT_TOLERANCE: a face joining a floor 0.004 off its own plane moves the floor's cuts, and
-- under a ramp's foot that walls the crossing (ticket 37).
local COPLANAR_TOLERANCE = 0.001

-- A convex solid in world space: its vertices and faces (vertex index lists).
type Solid = { Points: { vector }, Faces: { { number } } }

-- A floor surface y = A x + B z + C, with the walkable faces that lie on it.
type Floor = { Name: string, A: number, B: number, C: number, Rings: { { vector } }, Areas: { any } }

local function height(f: Floor, x: number, z: number): number
	return f.A * x + f.B * z + f.C
end

-- The Part's shape as a convex solid in its own space: (points, faces).
local function localSolid(part: BasePart, sides: number): ({ vector }, { { number } })
	local s = part.Size
	local hx, hy, hz = s.X / 2, s.Y / 2, s.Z / 2
	local shape = if part:IsA("WedgePart") then "Wedge" elseif part:IsA("Part") then (part :: Part).Shape.Name else ""
	if shape == "Block" then
		local p = {}
		for i = 0, 7 do
			table.insert(
				p,
				vector.create(
					if i % 2 == 0 then -hx else hx,
					if i // 2 % 2 == 0 then -hy else hy,
					if i < 4 then -hz else hz
				)
			)
		end
		-- index = 1 + x + 2 y + 4 z (bits)
		return p, { { 1, 2, 4, 3 }, { 5, 6, 8, 7 }, { 1, 2, 6, 5 }, { 3, 4, 8, 7 }, { 1, 3, 7, 5 }, { 2, 4, 8, 6 } }
	elseif shape == "Wedge" then
		-- Bottom and back (+Z) faces are full; the slope runs from the bottom front edge up to
		-- the top back edge.
		local p = {
			vector.create(-hx, -hy, -hz),
			vector.create(hx, -hy, -hz),
			vector.create(-hx, -hy, hz),
			vector.create(hx, -hy, hz),
			vector.create(-hx, hy, hz),
			vector.create(hx, hy, hz),
		}
		return p, { { 1, 2, 4, 3 }, { 3, 4, 6, 5 }, { 1, 2, 6, 5 }, { 1, 3, 5 }, { 2, 4, 6 } }
	elseif shape == "Cylinder" then
		-- Axis along X; the circle's diameter is the smaller of Y and Z.
		local r = math.min(s.Y, s.Z) / 2
		local p, a, b, faces = {}, {}, {}, {}
		for i = 0, sides - 1 do
			local t = 2 * math.pi * i / sides
			table.insert(p, vector.create(-hx, r * math.cos(t), r * math.sin(t)))
			table.insert(p, vector.create(hx, r * math.cos(t), r * math.sin(t)))
			table.insert(a, 2 * i + 1)
			table.insert(b, 2 * i + 2)
			local j = (i + 1) % sides
			table.insert(faces, { 2 * i + 1, 2 * i + 2, 2 * j + 2, 2 * j + 1 })
		end
		table.insert(faces, a)
		table.insert(faces, b)
		return p, faces
	end
	error(
		`NavMeshAdapter: {part:GetFullName()} is a {part.ClassName} ({shape}); only blocks, wedges and cylinders are supported`,
		3
	)
end

local function toWorld(part: BasePart, sides: number): Solid
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = part.CFrame:GetComponents()
	local points, faces = localSolid(part, sides)
	for i, p in points do
		points[i] = vector.create(
			x + r00 * p.x + r01 * p.y + r02 * p.z,
			y + r10 * p.x + r11 * p.y + r12 * p.z,
			z + r20 * p.x + r21 * p.y + r22 * p.z
		)
	end
	return { Points = points, Faces = faces }
end

-- The face's outward unit normal (outward: away from the solid's centroid).
local function faceNormal(solid: Solid, face: { number }, centroid: vector): vector
	local p = solid.Points
	local a = p[face[1]]
	local n = vector.cross(p[face[2]] - a, p[face[3]] - a)
	if vector.dot(n, a - centroid) < 0 then
		n = -n
	end
	return vector.normalize(n)
end

local function centroidOf(points: { vector }): vector
	local sum = vector.zero
	for _, p in points do
		sum += p
	end
	return sum / #points
end

-- Andrew's monotone chain over the XZ projection; returns the hull CCW (seen from above, +Y).
local function hull2D(points: { vector }): { vector }
	local pts = table.clone(points)
	table.sort(pts, function(a, b)
		return a.x < b.x or (a.x == b.x and a.z < b.z)
	end)
	local function cross(o: vector, a: vector, b: vector): number
		return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
	end
	local out = {}
	for pass = 1, 2 do
		local start = #out
		for i = if pass == 1 then 1 else #pts, if pass == 1 then #pts else 1, if pass == 1 then 1 else -1 do
			local p = pts[i]
			while #out >= start + 2 and cross(out[#out - 1], out[#out], p) <= 1e-12 do
				table.remove(out)
			end
			table.insert(out, p)
		end
		table.remove(out)
	end
	return out
end

local function area2D(ring: { vector }): number
	local sum = 0
	for i, a in ring do
		local b = ring[i % #ring + 1]
		sum += a.x * b.z - b.x * a.z
	end
	return sum / 2
end

-- Within HEIGHT_TOLERANCE of each other in plan.
local function close(p: vector, q: vector): boolean
	return math.abs(p.x - q.x) + math.abs(p.z - q.z) <= HEIGHT_TOLERANCE
end

-- Where the solid stands within [0, agentHeight) above the floor: the footprint of that slice,
-- or nil when the solid only touches the floor (a Part of the floor itself, or one below it).
-- An agent fits under a ceiling exactly agentHeight up.
local function cut(solid: Solid, floor: Floor, agentHeight: number): { vector }?
	local pts, top = {}, 0
	local s = {}
	for i, p in solid.Points do
		s[i] = p.y - height(floor, p.x, p.z)
		if s[i] >= 0 and s[i] < agentHeight then
			table.insert(pts, p)
			top = math.max(top, s[i])
		end
	end
	local seen = {}
	for _, face in solid.Faces do
		for k, i in face do
			local j = face[k % #face + 1]
			local key = math.min(i, j) * 4096 + math.max(i, j)
			if seen[key] then
				continue
			end
			seen[key] = true
			for _, level in { 0, agentHeight } do
				if (s[i] - level) * (s[j] - level) < 0 then
					local t = (level - s[i]) / (s[j] - s[i])
					table.insert(pts, solid.Points[i] + (solid.Points[j] - solid.Points[i]) * t)
					top = math.max(top, level)
				end
			end
		end
	end
	if top <= HEIGHT_TOLERANCE then
		return nil
	end
	-- Hull corners closer than HEIGHT_TOLERANCE are one corner: f32 noise puts them there, and
	-- on the core's grid they can swap and fold the ring.
	local ring = {}
	for _, p in hull2D(pts) do
		if ring[1] == nil or not close(p, ring[#ring]) then
			table.insert(ring, p)
		end
	end
	if close(ring[1], ring[#ring]) then
		table.remove(ring)
	end
	if area2D(ring) <= 1e-6 then -- a plate with no thickness
		return nil
	end
	for i, p in ring do
		ring[i] = vector.create(p.x, height(floor, p.x, p.z), p.z)
	end
	return ring
end

-- The parameter interval [t0, t1] of segment a->b inside the convex CCW ring (XZ), or nil. A
-- segment along one of the ring's edges (a hinge) is inside it unless HEIGHT_TOLERANCE outside.
local function clipSegment(a: vector, b: vector, ring: { vector }): (number?, number?)
	local t0, t1 = 0, 1
	local d = b - a
	for i, p in ring do
		local q = ring[i % #ring + 1]
		-- inside: cross(q - p, x - p) >= 0 for a CCW ring
		local ex, ez = q.x - p.x, q.z - p.z
		local num = ex * (a.z - p.z) - ez * (a.x - p.x)
		local den = ex * d.z - ez * d.x
		local len = math.sqrt(ex * ex + ez * ez)
		if math.abs(den) < 1e-4 * len * vector.magnitude(d) then -- parallel, to f32 precision
			if num < -HEIGHT_TOLERANCE * len then
				return nil, nil
			end
		else
			local t = -num / den
			if den > 0 then
				t0 = math.max(t0, t)
			else
				t1 = math.min(t1, t)
			end
		end
	end
	if t1 - t0 <= 1e-9 then
		return nil, nil
	end
	return t0, t1
end

local function planeOf(ring: { vector }, n: vector): (number, number, number)
	local p = ring[1]
	local a, b = -n.x / n.y, -n.z / n.y
	return a, b, p.y - a * p.x - b * p.z
end

-- The point of segment a-b nearest v, in XZ: (x, z, distance).
local function closest(v: vector, a: vector, b: vector): (number, number, number)
	local dx, dz = b.x - a.x, b.z - a.z
	local t = math.clamp(((v.x - a.x) * dx + (v.z - a.z) * dz) / (dx * dx + dz * dz), 0, 1)
	local x, z = a.x + dx * t, a.z + dz * t
	return x, z, math.sqrt((v.x - x) ^ 2 + (v.z - z) ^ 2)
end

-- Is p inside or on the convex CCW ring (XZ)?
local function inside(p: vector, ring: { vector }): boolean
	for i, a in ring do
		local b = ring[i % #ring + 1]
		if (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x) < -1e-9 then
			return false
		end
	end
	return true
end

-- Welds the cracks between a floor's faces: Parts placed edge to edge leave cracks of
-- hundredths of a stud, and the core makes every crack a wall (decision D3 keeps welding out of
-- the core). A vertex within `tolerance` of another face's edge, and outside that face, moves
-- onto the edge; faces are measured before any move, so the result does not depend on order.
-- ponytail: every vertex against every edge of the floor, O(faces^2); bucket faces on a grid if
-- a level with thousands of floor Parts shows up slow.
local function weld(f: Floor, tolerance: number)
	local before = {}
	for i, ring in f.Rings do
		before[i] = table.clone(ring)
	end
	for i, ring in f.Rings do
		for k, v in before[i] do
			local best, bestDistance = nil, tolerance
			for j, other in before do
				if j == i or inside(v, other) then
					continue
				end
				for e, a in other do
					local x, z, distance = closest(v, a, other[e % #other + 1])
					if distance < bestDistance then
						best, bestDistance = vector.create(x, height(f, x, z), z), distance
					end
				end
			end
			if best then
				ring[k] = best
			end
		end
	end
end

-- Drops corners on a straight line between their neighbours (within HEIGHT_TOLERANCE).
local function straighten(ring: { vector }): { vector }
	local i = 1
	while #ring > 3 and i <= #ring do
		local a, b, c = ring[(i - 2) % #ring + 1], ring[i], ring[i % #ring + 1]
		local cross = (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)
		local len = math.sqrt((c.x - a.x) ^ 2 + (c.z - a.z) ^ 2)
		if math.abs(cross) / len <= HEIGHT_TOLERANCE then -- 0 / 0 (a spike) keeps it
			table.remove(ring, i)
		else
			i += 1
		end
	end
	return ring
end

-- The edge r1[a] -> r1[a + 1] that r2 runs the other way, from r2[b] to r2[b + 1]; nil if none.
local function sharedEdge(r1: { vector }, r2: { vector }): (number?, number?)
	for a = 1, #r1 do
		local u, v = r1[a], r1[a % #r1 + 1]
		for b = 1, #r2 do
			if close(r2[b], v) and close(r2[b % #r2 + 1], u) then
				return a, b
			end
		end
	end
	return nil, nil
end

-- Joins a floor's faces that share an edge into one ring, without the corners that leaves on a
-- straight line: a triangle built from two WedgeParts is one triangle again, so its neighbours
-- see whole edges (a corner mid-edge snaps off it in the core).
-- ponytail: every pair of the floor's rings, O(rings^2 x corners^2); index edges if a floor of
-- thousands of Parts shows up slow.
local function join(f: Floor)
	local rings = f.Rings
	local i = 1
	while i <= #rings do
		local joined = false
		for j = i + 1, #rings do
			local a, b = sharedEdge(rings[i], rings[j])
			if a then
				-- rings[i] from the shared edge's far end round to its near end, then rings[j]
				-- between them.
				local r1, r2, out = rings[i], rings[j], {}
				for k = 0, #r1 - 1 do
					table.insert(out, r1[(a + k) % #r1 + 1])
				end
				for k = 2, #r2 - 1 do
					table.insert(out, r2[((b :: number) + k - 1) % #r2 + 1])
				end
				rings[i] = straighten(out)
				table.remove(rings, j)
				joined = true
				break
			end
		end
		if not joined then
			i += 1
		end
	end
end

-- The area-name table (research D5): each text `NavArea` gets an id from 2 up, in name order,
-- skipping ids a numeric `NavArea` already uses. Name order keeps ids independent of Part order.
local function nameAreas(walkable: { BasePart }): { [string]: number }
	local names, taken, seen = {}, {}, {}
	for _, part in walkable do
		local area = part:GetAttribute("NavArea")
		if type(area) == "number" then
			taken[area] = true
		elseif type(area) == "string" and not seen[area] then
			seen[area] = true
			table.insert(names, area)
		end
	end
	table.sort(names)
	local areas, id = {}, 2
	for _, name in names do
		while taken[id] do
			id += 1
		end
		areas[name] = id
		id += 1
	end
	return areas
end

type Face = { Ring: { vector }, Floor: Floor }
type Seam = { FloorA: string, FloorB: string, From: vector, To: vector }

-- How far a riser strip reaches out over the lower floor, in studs.
local STRIP_WIDTH = 0.25

-- Removes [t0, t1] from the sorted intervals (segment parameters).
local function subtract(intervals: { { number } }, t0: number, t1: number): { { number } }
	local out = {}
	for _, iv in intervals do
		if iv[1] < t0 then
			table.insert(out, { iv[1], math.min(iv[2], t0) })
		end
		if iv[2] > t1 then
			table.insert(out, { math.max(iv[1], t1), iv[2] })
		end
	end
	return out
end

-- The t range (along p + d t) of the part of convex `ring` within the band s0 <= s <= s1, where
-- s is the distance along `normal` from the line through p; nil if none of it is.
local function bandInterval(
	p: vector,
	d: vector,
	normal: vector,
	ring: { vector },
	s0: number,
	s1: number
): (number?, number?)
	local dd = d.x * d.x + d.z * d.z
	local pts = {}
	for _, v in ring do
		local w = v - p
		table.insert(pts, { (w.x * d.x + w.z * d.z) / dd, w.x * normal.x + w.z * normal.z })
	end
	for _, bound in { { s0, 1 }, { s1, -1 } } do -- keep (s - s0) >= 0, then (s1 - s) >= 0
		local kept = {}
		for i, a in pts do
			local b = pts[i % #pts + 1]
			local fa, fb = (a[2] - bound[1]) * bound[2], (b[2] - bound[1]) * bound[2]
			if fa >= 0 then
				table.insert(kept, a)
			end
			if fa * fb < 0 then
				local t = fa / (fa - fb)
				table.insert(kept, { a[1] + (b[1] - a[1]) * t, bound[1] })
			end
		end
		pts = kept
	end
	if #pts == 0 then
		return nil, nil
	end
	local lo, hi = math.huge, -math.huge
	for _, q in pts do
		lo, hi = math.min(lo, q[1]), math.max(hi, q[1])
	end
	return lo, hi
end

-- The step-height rule (ticket 34, ruled "ramp strips for now"): where an edge of a face lies
-- over another floor's face, above it by no more than `maxStep` (a stair riser, a curb), a strip
-- floor bridges the rise. The strip runs from the edge out STRIP_WIDTH over the lower face, is
-- cut out of the lower floor, and joins both floors with ordinary same-height seams (the core
-- refuses a seam whose sides differ in height; ticket 40 would let it).
-- - The lower face must reach past the strip, and the parts of the edge where a cut stands in
--   the strip's band (or just inside the edge, on the upper floor) are left out: Build rejects a seam with no walkable floor beside it.
-- - Strips are cut out of the lower floor as they are made, so where two meet at a corner the
--   later one stops at the earlier.
local function riserStrips(
	faces: { Face },
	floorDescs: { [string]: any },
	maxStep: number,
	names: { [string]: true },
	seams: { Seam }
)
	for _, upper in faces do
		local ring = upper.Ring
		for i, p in ring do
			local q = ring[i % #ring + 1]
			local d = q - p
			local length = math.sqrt(d.x * d.x + d.z * d.z)
			if length <= 1e-6 then
				continue
			end
			local normal = vector.create(d.z, 0, -d.x) / length -- the ring is CCW: right is out
			local out, beyond = normal * STRIP_WIDTH, normal * (STRIP_WIDTH + 0.01)
			for _, lower in faces do
				local L = lower.Floor
				if L == upper.Floor then
					continue
				end
				local t0, t1 = clipSegment(p + beyond, q + beyond, lower.Ring)
				if t0 == nil then
					continue
				end
				local fine = true
				for _, t in { t0 :: number, t1 :: number } do
					local u = p + d * t
					local rise = u.y - height(L, u.x, u.z)
					fine = fine and rise > HEIGHT_TOLERANCE and rise <= maxStep + HEIGHT_TOLERANCE
				end
				if not fine then
					continue
				end
				local intervals = { { t0 :: number, t1 :: number } }
				-- Cuts over the strip's band on the lower floor, or just inside the edge on the upper.
				for _, side in { { L.Name, 0.001, STRIP_WIDTH + 0.01 }, { upper.Floor.Name, -0.01, -0.001 } } do
					for _, cutRing in floorDescs[side[1]].Obstacles or {} do
						local c0, c1 = bandInterval(p, d, normal, cutRing, side[2], side[3])
						if c0 then
							intervals = subtract(intervals, c0, c1 :: number)
						end
					end
				end
				local function low(v: vector): vector
					return vector.create(v.x, height(L, v.x, v.z), v.z)
				end
				for _, iv in intervals do
					if (iv[2] - iv[1]) * length <= 1e-3 then
						continue
					end
					local from, to = p + d * iv[1], p + d * iv[2]
					local name, k = "Riser", 1
					while names[name] do
						k += 1
						name = `Riser {k}`
					end
					names[name] = true
					local lf, lt = low(from + out), low(to + out)
					floorDescs[name] = { Walkable = { { lt, to, from, lf } } } -- CCW: out is right of from->to
					floorDescs[L.Name].Obstacles = floorDescs[L.Name].Obstacles or {}
					table.insert(floorDescs[L.Name].Obstacles, { lt, low(to), low(from), lf })
					table.insert(seams, { FloorA = name, FloorB = upper.Floor.Name, From = from, To = to })
					table.insert(seams, { FloorA = L.Name, FloorB = name, From = lf, To = lt })
				end
			end
		end
	end
end

--[=[
	@within NavMeshAdapter
	@param walkable { BasePart } -- Parts whose upward faces are walkable
	@param obstacles { BasePart } -- the other solid Parts: crates, walls, props
	@param options AdapterOptions?
	@return NavMesh.NavMeshDesc -- Floors and Seams; add Links and MaxAgentRadius yourself
	@return { [string]: number } -- area id per `NavArea` name

	A walkable Part with a `NavArea` attribute marks its walkable faces as an area (later Parts
	win where areas overlap). A number is the area id; text is a name, and the second result
	maps each name to its id (2 up, in name order, skipping ids used as numbers).

	```lua
	local desc, areas = NavMeshAdapter.FromParts(
		CollectionService:GetTagged("Walkable"),
		Level.Props:GetChildren()
	)
	desc.MaxAgentRadius = 2
	local mesh = NavMesh.Build(desc)
	local filter = { AreaCosts = { [areas.Road] = 10 } }
	```
]=]
local function fromParts(
	walkable: { BasePart },
	obstacles: { BasePart },
	options: AdapterOptions?
): (NavMesh.NavMeshDesc, { [string]: number })
	local o: AdapterOptions = options or {}
	local areaIds = nameAreas(walkable)
	local agentHeight = o.AgentHeight or 5
	local minUp = math.cos(math.rad(o.MaxSlope or 45))
	local sides = o.CylinderSides or 16
	local weldTolerance = o.WeldTolerance or 0.05
	local maxStep = o.MaxStepHeight or 0

	-- Walkable faces, grouped into floors by plane.
	local floors: { Floor } = {}
	local names: { [string]: true } = {}
	local solids: { Solid } = {}
	local faces: { Face } = {}
	for _, part in walkable do
		local solid = toWorld(part, sides)
		table.insert(solids, solid)
		local centroid = centroidOf(solid.Points)
		for _, face in solid.Faces do
			local n = faceNormal(solid, face, centroid)
			if n.y < minUp then
				continue
			end
			local ring = {}
			for _, i in face do
				table.insert(ring, solid.Points[i])
			end
			if area2D(ring) < 0 then
				local m = #ring
				for i = 1, m // 2 do
					ring[i], ring[m + 1 - i] = ring[m + 1 - i], ring[i]
				end
			end
			local a, b, c = planeOf(ring, n)
			local floor: Floor? = nil
			for _, f in floors do
				local on = true -- every corner on f's plane: the face lies in it
				for _, p in ring do
					on = on and math.abs(height(f, p.x, p.z) - p.y) <= COPLANAR_TOLERANCE
				end
				if on then
					floor = f
					break
				end
			end
			if floor == nil then
				local name, k = part.Name, 1
				while names[name] do
					k += 1
					name = `{part.Name} {k}`
				end
				names[name] = true
				floor = { Name = name, A = a, B = b, C = c, Rings = {}, Areas = {} }
				table.insert(floors, floor :: Floor)
			end
			local f = floor :: Floor
			for i, p in ring do
				ring[i] = vector.create(p.x, height(f, p.x, p.z), p.z) -- exactly on the floor's plane
			end
			table.insert(f.Rings, ring)
			local area = part:GetAttribute("NavArea")
			if type(area) == "string" then
				area = areaIds[area]
			end
			if type(area) == "number" then
				table.insert(f.Areas, { Polygon = ring, Area = area })
			end
		end
	end
	for _, part in obstacles do
		table.insert(solids, toWorld(part, sides))
	end

	-- Each floor: its welded faces, minus every solid standing within the agent's height.
	local seams: { Seam } = {}
	local desc = { Floors = {}, Seams = seams }
	for _, f in floors do
		if weldTolerance > 0 then
			weld(f, weldTolerance)
		end
		join(f)
		for _, ring in f.Rings do
			table.insert(faces, { Ring = ring, Floor = f })
		end
		local lo, hi = vector.one * math.huge, vector.one * -math.huge
		for _, ring in f.Rings do
			for _, p in ring do
				lo, hi = vector.min(lo, p), vector.max(hi, p)
			end
		end
		local obstacleRings = {}
		for _, solid in solids do
			local ring = cut(solid, f, agentHeight)
			if ring == nil then
				continue
			end
			local clo, chi = vector.one * math.huge, vector.one * -math.huge
			for _, p in ring do
				clo, chi = vector.min(clo, p), vector.max(chi, p)
			end
			-- A Part far off can still cut the floor's plane: keep only cuts over the floor.
			if chi.x > lo.x and clo.x < hi.x and chi.z > lo.z and clo.z < hi.z then
				table.insert(obstacleRings, ring)
			end
		end
		desc.Floors[f.Name] = {
			Walkable = f.Rings,
			Obstacles = if #obstacleRings > 0 then obstacleRings else nil,
			Areas = if #f.Areas > 0 then f.Areas else nil,
		}
	end

	-- Seams: an edge of a face on one floor that lies on another floor's face, clipped to it.
	-- Two faces sharing an edge find it from both sides: keep the first.
	local function known(a: string, b: string, from: vector, to: vector): boolean
		for _, seam in desc.Seams do
			if
				(seam.FloorA == a and seam.FloorB == b or seam.FloorA == b and seam.FloorB == a)
				and select(3, closest(from, seam.From, seam.To)) <= HEIGHT_TOLERANCE
				and select(3, closest(to, seam.From, seam.To)) <= HEIGHT_TOLERANCE
			then
				return true
			end
		end
		return false
	end
	for _, fb in faces do
		local ring = fb.Ring
		for i, p in ring do
			local q = ring[i % #ring + 1]
			for _, fa in faces do
				local A = fa.Floor
				if
					A == fb.Floor
					or math.abs(height(A, p.x, p.z) - p.y) > HEIGHT_TOLERANCE
					or math.abs(height(A, q.x, q.z) - q.y) > HEIGHT_TOLERANCE
				then
					continue
				end
				local t0, t1 = clipSegment(p, q, fa.Ring)
				if t0 == nil or ((t1 :: number) - t0) * vector.magnitude(q - p) < HEIGHT_TOLERANCE then
					continue -- a face touching the edge at a corner only
				end
				local from, to = p + (q - p) * t0, p + (q - p) * (t1 :: number)
				if not known(A.Name, fb.Floor.Name, from, to) then
					table.insert(desc.Seams, { FloorA = A.Name, FloorB = fb.Floor.Name, From = from, To = to })
				end
			end
		end
	end
	if maxStep > 0 then
		riserStrips(faces, desc.Floors, maxStep, names, seams)
	end
	return desc :: any, areaIds -- `vector` points; the public types still say Vector3 (ticket 26)
end

return {
	FromParts = fromParts,
}
