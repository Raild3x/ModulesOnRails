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

local Snap = require("../../Snap")
local Storage = require("../../Storage")

local H = 0.05
local MIN_H = 0.002
local HASH = 2
local ON_MESH = vector.create(1e-4, 50, 1e-4)

local Flood = {}

local function pointSeg(px: number, pz: number, w: { number }): number
	local dx, dz = w[3] - w[1], w[4] - w[2]
	local len2 = dx * dx + dz * dz
	local u = if len2 > 0 then math.clamp(((px - w[1]) * dx + (pz - w[2]) * dz) / len2, 0, 1) else 0
	return math.sqrt((w[1] + u * dx - px) ^ 2 + (w[2] + u * dz - pz) ^ 2)
end

export type Oracle = {
	Mesh: any,
	-- Distance from (x, z) to the nearest wall edge, or `cap` when none is nearer.
	Clearance: (x: number, z: number, cap: number) -> number,
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
	return {
		Mesh = mesh,
		Clearance = function(x: number, z: number, cap: number): number
			local best = cap
			local reach = math.ceil(cap / HASH)
			local ci, cj = math.floor(x / HASH), math.floor(z / HASH)
			for i = ci - reach, ci + reach do
				for j = cj - reach, cj + reach do
					for _, w in hash[key(i, j)] or {} do
						best = math.min(best, pointSeg(x, z, w))
					end
				end
			end
			return best
		end,
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
	for side, p in { a, b } do
		local i, j = math.floor(p.X / H), math.floor(p.Z / H)
		local k = key(i, j)
		if state[k] ~= nil and state[k] ~= side then
			return true
		end
		state[k] = side
		table.insert(queues[side], { i, j })
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
								state[k] = side
								table.insert(q, { i, j })
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
