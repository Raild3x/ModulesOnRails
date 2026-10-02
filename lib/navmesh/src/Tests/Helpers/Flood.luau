-- Authors: Logan Hunt (Raildex)
-- September 28, 2026
-- An independent reachability oracle for agent radius (ticket 27): a grid flood over free
-- space, knowing nothing of triangles, corridors or widths. Reads go through Storage accessors.
--
-- `Connected` is liberal: a cell (side h) counts as free when it may hold a point on the mesh at
-- least r from every wall edge. Its centre must then be on the mesh and at least r - h*sqrt(2)/2
-- from every wall (for r > h*sqrt(2)); a square that passes but whose centre is nearer than r is
-- split 5 x 5, down to MIN_H. Cells are 8-connected. So every free path runs through free cells,
-- and two ends it cannot connect are truly parted at radius r. It floods from both ends in turn
-- and stops when either side runs out, which keeps a small pocket cheap.
--
-- Links (E3) are teleports between their two snapped ends, one way unless bidirectional;
-- disabled ones are skipped. A link is taken from the cell of its start, or of the start pushed
-- straight out of its nearest wall to r (where an agent touching the wall would stand, as the
-- search judges link points), and lands in the cells of its end and of its end pushed out the
-- same way, free or not. From b the flood runs links backwards.

local Snap = require("../../Snap")
local Storage = require("../../Storage")

local H = 0.05
local MIN_H = 0.002
local HASH = 2
local ON_MESH = vector.create(1e-4, 50, 1e-4)

local Flood = {}

-- Distance from (px, pz) to segment w, and the nearest point.
local function pointSeg(px: number, pz: number, w: { number }): (number, number, number)
	local dx, dz = w[3] - w[1], w[4] - w[2]
	local len2 = dx * dx + dz * dz
	local u = if len2 > 0 then math.clamp(((px - w[1]) * dx + (pz - w[2]) * dz) / len2, 0, 1) else 0
	local qx, qz = w[1] + u * dx, w[2] + u * dz
	return math.sqrt((qx - px) ^ 2 + (qz - pz) ^ 2), qx, qz
end

export type Oracle = {
	Mesh: any,
	-- Distance from (x, z) to the nearest wall edge, or `cap` when none is nearer.
	Clearance: (x: number, z: number, cap: number) -> number,
	-- The nearest wall point within `cap` of (x, z), and its distance (nil when none).
	Nearest: (x: number, z: number, cap: number) -> (number, number?, number?),
	-- Enabled links: { from, to, bidirectional }.
	Links: { { any } },
}

--[=[
	The oracle for a mesh: its wall edges (neighbourless, not open) in a spatial hash.
]=]
function Flood.New(mesh: any): Oracle
	local hash: { [number]: { { number } } } = {}
	local function key(i: number, j: number): number
		return (i + 100000) * 1000000 + (j + 100000)
	end
	for t = 1, Storage.TriangleCount(mesh) do
		local verts = { Storage.GetTriangle(mesh, t) }
		for e = 1, 3 do
			if Storage.IsWallEdge(mesh, t, e) then
				local p, q = Storage.GetVertex(mesh, verts[e % 3 + 1]), Storage.GetVertex(mesh, verts[(e + 1) % 3 + 1])
				local w = { p.X, p.Z, q.X, q.Z }
				for i = math.floor(math.min(p.X, q.X) / HASH), math.floor(math.max(p.X, q.X) / HASH) do
					for j = math.floor(math.min(p.Z, q.Z) / HASH), math.floor(math.max(p.Z, q.Z) / HASH) do
						local list = hash[key(i, j)] or {}
						hash[key(i, j)] = list
						table.insert(list, w)
					end
				end
			end
		end
	end
	local function nearest(x: number, z: number, cap: number): (number, number?, number?)
		local best, bx, bz = cap, nil, nil
		local reach = math.ceil(cap / HASH)
		local ci, cj = math.floor(x / HASH), math.floor(z / HASH)
		for i = ci - reach, ci + reach do
			for j = cj - reach, cj + reach do
				for _, w in hash[key(i, j)] or {} do
					local d, qx, qz = pointSeg(x, z, w)
					if d < best then
						best, bx, bz = d, qx, qz
					end
				end
			end
		end
		return best, bx, bz
	end
	local links = {}
	for id = 1, Storage.LinkCount(mesh) do
		local fromTri, from, toTri, to, _, _, _, both, enabled = Storage.GetLink(mesh, id)
		if enabled and fromTri ~= 0 and toTri ~= 0 then -- a free slot (sparse ids) has no ends
			table.insert(links, { from, to, both })
		end
	end
	return {
		Mesh = mesh,
		Clearance = function(x: number, z: number, cap: number): number
			return (nearest(x, z, cap))
		end,
		Nearest = nearest,
		Links = links,
	}
end

--[=[
	Whether (x, z) is on the mesh (any floor, within 1e-4 horizontally).
]=]
function Flood.OnMesh(oracle: Oracle, x: number, z: number): boolean
	local _, p = Snap.Snap(oracle.Mesh, vector.create(x, 0, z), ON_MESH, {})
	return p ~= nil
end

--[=[
	Whether a and b may be connected at radius r (see the module notes): false proves they are
	not. Each end's own cell is where its flood starts, free or not.
]=]
function Flood.Connected(oracle: Oracle, r: number, a: vector, b: vector): boolean
	local clearance = oracle.Clearance
	local function mayHoldFree(x0: number, z0: number, h: number): boolean
		local x, z = x0 + h / 2, z0 + h / 2
		local c = clearance(x, z, r + 0.01)
		if c < r - h * math.sqrt(2) / 2 or not Flood.OnMesh(oracle, x, z) then
			return false
		end
		if c >= r or h <= MIN_H then
			return true
		end
		for i = 0, 4 do
			for j = 0, 4 do
				if mayHoldFree(x0 + i * h / 5, z0 + j * h / 5, h / 5) then
					return true
				end
			end
		end
		return false
	end
	local state: { [number]: number } = {} -- cell -> 1 (from a), 2 (from b), -1 (not free)
	local function key(i: number, j: number): number
		return (i + 1000000) * 4000000 + (j + 1000000)
	end
	local queues = { {}, {} }
	local heads = { 1, 1 }
	-- The cells of p and of p pushed out of its nearest wall to r (when that stands clear).
	local function cells(p: vector): { number }
		local out = { math.floor(p.X / H), math.floor(p.Z / H) }
		local d, qx, qz = oracle.Nearest(p.X, p.Z, r)
		if qx ~= nil and qz ~= nil and d > 0 then
			local x, z = qx + (p.X - qx) * r / d, qz + (p.Z - qz) * r / d
			if clearance(x, z, r) >= r * (1 - 1e-9) then
				table.insert(out, math.floor(x / H))
				table.insert(out, math.floor(z / H))
			end
		end
		return out
	end
	-- Per side, cell -> the link ends a flood reaching it jumps to.
	local jumps: { { [number]: { vector } } } = { {}, {} }
	local function jump(side: number, from: vector, to: vector)
		local at = cells(from)
		for c = 1, #at, 2 do
			local k = key(at[c], at[c + 1])
			jumps[side][k] = jumps[side][k] or {}
			table.insert(jumps[side][k], to)
		end
	end
	for _, l in oracle.Links do
		jump(1, l[1], l[2])
		jump(2, l[2], l[1])
		if l[3] then
			jump(1, l[2], l[1])
			jump(2, l[1], l[2])
		end
	end
	-- Claims cell (i, j) for `side`, free or not, and takes the links from it: true when that
	-- meets the other side.
	local function enter(side: number, i: number, j: number): boolean
		local k = key(i, j)
		local st = state[k]
		if st == side then
			return false
		elseif st ~= nil and st > 0 then
			return true
		end
		state[k] = side
		table.insert(queues[side], { i, j })
		for _, to in jumps[side][k] or {} do
			local at = cells(to)
			for c = 1, #at, 2 do
				if enter(side, at[c], at[c + 1]) then
					return true
				end
			end
		end
		return false
	end
	-- Each end floods from its own cell and from where it stands pushed off its nearest wall,
	-- as the search judges an end touching a wall (E3; ticket 27 started from its own cell only,
	-- which can't leave an end in a wall's disc and so "proved" any such end parted).
	for side, p in { a, b } do
		local at = cells(p)
		for c = 1, #at, 2 do
			if enter(side, at[c], at[c + 1]) then
				return true
			end
		end
	end
	while true do
		for side = 1, 2 do
			local q = queues[side]
			if heads[side] > #q then
				return false -- this side's component is exhausted without meeting the other
			end
			local cell = q[heads[side]]
			heads[side] += 1
			for di = -1, 1 do
				for dj = -1, 1 do
					if di ~= 0 or dj ~= 0 then
						local i, j = cell[1] + di, cell[2] + dj
						local k = key(i, j)
						local st = state[k]
						if st == nil then
							if mayHoldFree(i * H, j * H, H) then
								if enter(side, i, j) then
									return true
								end
							else
								state[k] = -1
							end
						elseif st > 0 and st ~= side then
							return true
						end
					end
				end
			end
		end
	end
end

return Flood
