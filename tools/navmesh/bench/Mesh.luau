--!native
-- Shared benchmark mesh: jittered side x side grid, each cell split along the diagonal that
-- passes the incircle test (locally Delaunay, so the visibility walk terminates). CCW
-- triangles; edge i is opposite vertex i; neighbour 0 = none.
local Mesh = {}

local function incircle(ax, ay, bx, by, cx, cy, px, py)
	local adx, ady = ax - px, ay - py
	local bdx, bdy = bx - px, by - py
	local cdx, cdy = cx - px, cy - py
	return (adx * adx + ady * ady) * (bdx * cdy - cdx * bdy)
		- (bdx * bdx + bdy * bdy) * (adx * cdy - cdx * ady)
		+ (cdx * cdx + cdy * cdy) * (adx * bdy - bdx * ady)
end

function Mesh.make(side: number, seed: number)
	local rng = Random.new(seed)
	local JITTER = 0.3
	local xs, ys = table.create(side * side), table.create(side * side)
	local function id(i, j)
		return j * side + i + 1
	end
	for j = 0, side - 1 do
		for i = 0, side - 1 do
			xs[id(i, j)] = i + (rng:NextNumber() - 0.5) * JITTER
			ys[id(i, j)] = j + (rng:NextNumber() - 0.5) * JITTER
		end
	end
	local tris = {}
	for j = 0, side - 2 do
		for i = 0, side - 2 do
			local a, b, c, d = id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1)
			-- Split along a-c unless d lies inside circle(a, b, c).
			if incircle(xs[a], ys[a], xs[b], ys[b], xs[c], ys[c], xs[d], ys[d]) > 0 then
				table.insert(tris, a)
				table.insert(tris, b)
				table.insert(tris, d)
				table.insert(tris, b)
				table.insert(tris, c)
				table.insert(tris, d)
			else
				table.insert(tris, a)
				table.insert(tris, b)
				table.insert(tris, c)
				table.insert(tris, a)
				table.insert(tris, c)
				table.insert(tris, d)
			end
		end
	end
	local T = #tris // 3
	local V = side * side
	local nbrs = table.create(3 * T, 0)
	local edges = {}
	for t = 1, T do
		local base = (t - 1) * 3
		for e = 1, 3 do
			local u = tris[base + (e % 3) + 1]
			local v = tris[base + ((e + 1) % 3) + 1]
			local key = if u < v then u * V + v else v * V + u
			local other = edges[key]
			if other then
				nbrs[base + e] = other[1]
				nbrs[(other[1] - 1) * 3 + other[2]] = t
			else
				edges[key] = { t, e }
			end
		end
	end
	local zs = table.create(V)
	for v = 1, V do
		zs[v] = 3 * math.sin(xs[v] * 0.21) * math.cos(ys[v] * 0.17) -- terrain height
	end
	return { xs = xs, ys = ys, zs = zs, tris = tris, nbrs = nbrs, V = V, T = T, side = side, tperm = nil }
end

-- AUDIT: same geometry, vertex ids and triangle ids randomly permuted (worst-case locality).
-- Per-triangle vertex order is kept, so CCW and "edge i opposite vertex i" still hold.
-- mode: "both" | "verts" | "tris"
function Mesh.shuffle(mesh, seed: number, mode: string)
	local rng = Random.new(seed)
	local V, T = mesh.V, mesh.T
	local function perm(n)
		local p = table.create(n)
		for i = 1, n do
			p[i] = i
		end
		for i = n, 2, -1 do
			local j = rng:NextInteger(1, i)
			p[i], p[j] = p[j], p[i]
		end
		return p
	end
	local vp = if mode ~= "tris" then perm(V) else nil -- old vertex -> new vertex
	local tp = if mode ~= "verts" then perm(T) else nil -- old tri -> new tri
	local xs, ys, zs = table.create(V), table.create(V), table.create(V)
	for v = 1, V do
		local nv = if vp then vp[v] else v
		xs[nv], ys[nv], zs[nv] = mesh.xs[v], mesh.ys[v], mesh.zs[v]
	end
	local tris, nbrs = table.create(3 * T), table.create(3 * T)
	for t = 1, T do
		local nt = if tp then tp[t] else t
		for e = 1, 3 do
			local ov = mesh.tris[(t - 1) * 3 + e]
			local on = mesh.nbrs[(t - 1) * 3 + e]
			tris[(nt - 1) * 3 + e] = if vp then vp[ov] else ov
			nbrs[(nt - 1) * 3 + e] = if on == 0 then 0 elseif tp then tp[on] else on
		end
	end
	return { xs = xs, ys = ys, zs = zs, tris = tris, nbrs = nbrs, V = V, T = T, side = mesh.side, tperm = tp }
end

return Mesh
