--!strict
--!native

local DelaunayUtil = require(script.Parent.DelaunayUtil)

export type TriangulationResult = {
	Triangles: { number },
	Halfedges: { number },
	Hull: { number },
}

export type Delaunay2dObject = {
	Update: (self: Delaunay2dObject) -> (),
	SetVertices: (self: Delaunay2dObject, vertices: { Vector2 }) -> (),
	SetCoords: (self: Delaunay2dObject, coords: { number }) -> (),
	GetCoords: (self: Delaunay2dObject) -> { number },
	GetTriangles: (self: Delaunay2dObject) -> { number },
	GetHalfedges: (self: Delaunay2dObject) -> { number },
	GetHull: (self: Delaunay2dObject) -> { number },
	GetEdges: (self: Delaunay2dObject) -> { { number } },
	ForEachTriangle: (self: Delaunay2dObject) -> () -> (number, number, number),
}

type Delaunay2dInternal = {
	coords: { number },
	_hashSize: number,
	_hullPrev: { number },
	_hullNext: { number },
	_hullTri: { number },
	_hullHash: { number },
	_ids: { number },
	_dists: { number },
	_triangles: { number },
	_halfedges: { number },
	_edgeStack: { number },
	trianglesLen: number,
	_cx: number,
	_cy: number,
	_hullStart: number,
	triangles: { number },
	halfedges: { number },
	hull: { number },
} & Delaunay2dObject

local Delaunay2d = {}
Delaunay2d.__index = Delaunay2d

local function coordX(coords: { number }, pointIndex: number): number
	return coords[pointIndex * 2 + 1]
end

local function coordY(coords: { number }, pointIndex: number): number
	return coords[pointIndex * 2 + 2]
end

local function copyArray(values: { number }): { number }
	local out = table.create(#values, 0)
	for i = 1, #values do
		out[i] = values[i]
	end
	return out
end

local function isNearlyEqual(a: number, b: number): boolean
	return math.abs(a - b) <= DelaunayUtil.EPSILON
end

local function buildCoordsFromVertices(vertices: { Vector2 }): { number }
	local coords = table.create(#vertices * 2, 0)
	for i, point in vertices do
		coords[i * 2 - 1] = point.X
		coords[i * 2] = point.Y
	end
	return coords
end

local function buildBasis(normal: Vector3): (Vector3, Vector3, Vector3)
	local n = normal.Magnitude > 0 and normal.Unit or Vector3.yAxis
	local ref = (math.abs(n:Dot(Vector3.yAxis)) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local u = n:Cross(ref)
	if u.Magnitude == 0 then
		u = n:Cross(Vector3.zAxis)
	end
	u = u.Unit
	local v = n:Cross(u).Unit
	return n, u, v
end

local function inferNormal(vertices: { Vector3 }): Vector3
	if #vertices < 3 then
		return Vector3.yAxis
	end

	local a = vertices[1]
	for i = 2, #vertices - 1 do
		for j = i + 1, #vertices do
			local cross = (vertices[i] - a):Cross(vertices[j] - a)
			if cross.Magnitude > 1e-9 then
				return cross.Unit
			end
		end
	end

	return Vector3.yAxis
end

local function projectVertices(vertices: { Vector3 }, normal: Vector3?): { Vector2 }
	local n = normal or inferNormal(vertices)
	local _, u, v = buildBasis(n)
	local origin = vertices[1] or Vector3.zero

	local projected = table.create(#vertices) :: { Vector2 }
	for i, point in vertices do
		local rel = point - origin
		projected[i] = Vector2.new(rel:Dot(u), rel:Dot(v))
	end

	return projected
end

local function allocState(self: Delaunay2dInternal, pointCount: number)
	local maxTriangles = math.max(2 * pointCount - 5, 0)
	self._triangles = table.create(maxTriangles * 3, 0)
	self._halfedges = table.create(maxTriangles * 3, -1)

	self._hashSize = math.max(1, math.ceil(math.sqrt(pointCount)))
	self._hullPrev = {}
	self._hullNext = {}
	self._hullTri = {}
	self._hullHash = table.create(self._hashSize, -1)

	self._ids = table.create(pointCount, 0)
	self._dists = table.create(pointCount, 0)

	self.trianglesLen = 0
	self._cx = 0
	self._cy = 0
	self._hullStart = 0

	self.triangles = {}
	self.halfedges = {}
	self.hull = {}
end

function Delaunay2d.new(vertices: { Vector2 }?): Delaunay2dObject
	local coords = buildCoordsFromVertices(vertices or {})
	local self = setmetatable({
		coords = coords,
		_hashSize = 1,
		_hullPrev = {},
		_hullNext = {},
		_hullTri = {},
		_hullHash = {},
		_ids = {},
		_dists = {},
		_triangles = {},
		_halfedges = {},
		_edgeStack = table.create(DelaunayUtil.EDGE_STACK_SIZE, 0),
		trianglesLen = 0,
		_cx = 0,
		_cy = 0,
		_hullStart = 0,
		triangles = {},
		halfedges = {},
		hull = {},
	}, Delaunay2d) :: any

	allocState(self, #coords // 2)
	Delaunay2d.Update(self)
	return self
end

function Delaunay2d.FromCoords(coords: { number }): Delaunay2dObject
	local object = Delaunay2d.new() :: Delaunay2dInternal
	Delaunay2d.SetCoords(object, coords)
	return object
end

function Delaunay2d.SetVertices(self: Delaunay2dInternal, vertices: { Vector2 })
	self.coords = buildCoordsFromVertices(vertices)
	allocState(self, #vertices)
	Delaunay2d.Update(self)
end

function Delaunay2d.SetCoords(self: Delaunay2dInternal, coords: { number })
	if #coords % 2 ~= 0 then
		error("Delaunay2d.SetCoords: coords length must be even")
	end

	self.coords = copyArray(coords)
	allocState(self, #coords // 2)
	Delaunay2d.Update(self)
end

function Delaunay2d.GetCoords(self: Delaunay2dInternal): { number }
	return self.coords
end

function Delaunay2d._hashKey(self: Delaunay2dInternal, x: number, y: number): number
	return math.floor(DelaunayUtil.PseudoAngle(x - self._cx, y - self._cy) * self._hashSize) % self._hashSize
end

function Delaunay2d._link(self: Delaunay2dInternal, a: number, b: number)
	self._halfedges[a + 1] = b
	if b ~= -1 then
		self._halfedges[b + 1] = a
	end
end

function Delaunay2d._addTriangle(
	self: Delaunay2dInternal,
	i0: number,
	i1: number,
	i2: number,
	a: number,
	b: number,
	c: number
): number
	local t = self.trianglesLen

	self._triangles[t + 1] = i0
	self._triangles[t + 2] = i1
	self._triangles[t + 3] = i2

	Delaunay2d._link(self, t, a)
	Delaunay2d._link(self, t + 1, b)
	Delaunay2d._link(self, t + 2, c)

	self.trianglesLen += 3
	return t
end

function Delaunay2d._legalize(self: Delaunay2dInternal, aStart: number): number
	local triangles = self._triangles
	local halfedges = self._halfedges
	local coords = self.coords
	local edgeStack = self._edgeStack

	local i = 0
	local a = aStart
	local ar = 0

	while true do
		local b = halfedges[a + 1]
		local a0 = a - (a % 3)
		ar = a0 + ((a + 2) % 3)

		if b == -1 then
			if i == 0 then
				break
			end
			i -= 1
			a = edgeStack[i + 1]
			continue
		end

		local b0 = b - (b % 3)
		local al = a0 + ((a + 1) % 3)
		local bl = b0 + ((b + 2) % 3)

		local p0 = triangles[ar + 1]
		local pr = triangles[a + 1]
		local pl = triangles[al + 1]
		local p1 = triangles[bl + 1]

		local illegal = DelaunayUtil.InCircle(
			coordX(coords, p0),
			coordY(coords, p0),
			coordX(coords, pr),
			coordY(coords, pr),
			coordX(coords, pl),
			coordY(coords, pl),
			coordX(coords, p1),
			coordY(coords, p1)
		)

		if illegal then
			triangles[a + 1] = p1
			triangles[b + 1] = p0

			local hbl = halfedges[bl + 1]

			if hbl == -1 then
				local e = self._hullStart
				repeat
					if self._hullTri[e] == bl then
						self._hullTri[e] = a
						break
					end
					e = self._hullPrev[e]
				until e == self._hullStart
			end

			Delaunay2d._link(self, a, hbl)
			Delaunay2d._link(self, b, halfedges[ar + 1])
			Delaunay2d._link(self, ar, bl)

			local br = b0 + ((b + 1) % 3)
			if i < #edgeStack then
				i += 1
				edgeStack[i] = br
			end
		else
			if i == 0 then
				break
			end
			i -= 1
			a = edgeStack[i + 1]
		end
	end

	return ar
end

function Delaunay2d.Update(self: Delaunay2dInternal)
	local coords = self.coords
	local n = #coords // 2

	if n == 0 then
		self.hull = {}
		self.triangles = {}
		self.halfedges = {}
		self.trianglesLen = 0
		return
	end

	if n == 1 then
		self.hull = { 0 }
		self.triangles = {}
		self.halfedges = {}
		self.trianglesLen = 0
		return
	end

	if n == 2 then
		local x0, y0 = coordX(coords, 0), coordY(coords, 0)
		local x1, y1 = coordX(coords, 1), coordY(coords, 1)
		if isNearlyEqual(x0, x1) and isNearlyEqual(y0, y1) then
			self.hull = { 0 }
		else
			self.hull = { 1, 0 }
		end
		self.triangles = {}
		self.halfedges = {}
		self.trianglesLen = 0
		return
	end

	allocState(self, n)

	local hullPrev = self._hullPrev
	local hullNext = self._hullNext
	local hullTri = self._hullTri
	local hullHash = self._hullHash

	local minX = math.huge
	local minY = math.huge
	local maxX = -math.huge
	local maxY = -math.huge

	for i = 0, n - 1 do
		local x = coordX(coords, i)
		local y = coordY(coords, i)

		if x < minX then
			minX = x
		end
		if y < minY then
			minY = y
		end
		if x > maxX then
			maxX = x
		end
		if y > maxY then
			maxY = y
		end

		self._ids[i + 1] = i
	end

	local cx = (minX + maxX) / 2
	local cy = (minY + maxY) / 2

	local i0, i1, i2 = 0, 0, 0

	do
		local minDist = math.huge
		for i = 0, n - 1 do
			local d = DelaunayUtil.Dist(cx, cy, coordX(coords, i), coordY(coords, i))
			if d < minDist then
				minDist = d
				i0 = i
			end
		end
	end

	local i0x = coordX(coords, i0)
	local i0y = coordY(coords, i0)

	do
		local minDist = math.huge
		for i = 0, n - 1 do
			if i ~= i0 then
				local d = DelaunayUtil.Dist(i0x, i0y, coordX(coords, i), coordY(coords, i))
				if d < minDist and d > 0 then
					minDist = d
					i1 = i
				end
			end
		end
	end

	local i1x = coordX(coords, i1)
	local i1y = coordY(coords, i1)

	local minRadius = math.huge
	for i = 0, n - 1 do
		if i ~= i0 and i ~= i1 then
			local r = DelaunayUtil.Circumradius(i0x, i0y, i1x, i1y, coordX(coords, i), coordY(coords, i))
			if r < minRadius then
				minRadius = r
				i2 = i
			end
		end
	end

	local i2x = coordX(coords, i2)
	local i2y = coordY(coords, i2)

	if minRadius == math.huge then
		for i = 0, n - 1 do
			local x = coordX(coords, i)
			local y = coordY(coords, i)
			self._dists[i + 1] = (x - coordX(coords, 0)) ~= 0 and (x - coordX(coords, 0)) or (y - coordY(coords, 0))
		end

		DelaunayUtil.Quicksort(self._ids, self._dists, 1, n)

		local hull = table.create(n, 0)
		local j = 0
		local d0 = -math.huge
		for i = 1, n do
			local id = self._ids[i]
			local d = self._dists[id + 1]
			if d > d0 then
				j += 1
				hull[j] = id
				d0 = d
			end
		end

		self.hull = hull
		self.triangles = {}
		self.halfedges = {}
		self.trianglesLen = 0
		return
	end

	if DelaunayUtil.Orient2d(i0x, i0y, i1x, i1y, i2x, i2y) < 0 then
		i1, i2 = i2, i1
		i1x, i2x = i2x, i1x
		i1y, i2y = i2y, i1y
	end

	local ccx, ccy = DelaunayUtil.Circumcenter(i0x, i0y, i1x, i1y, i2x, i2y)
	self._cx = ccx
	self._cy = ccy

	for i = 0, n - 1 do
		self._dists[i + 1] = DelaunayUtil.Dist(coordX(coords, i), coordY(coords, i), ccx, ccy)
	end

	DelaunayUtil.Quicksort(self._ids, self._dists, 1, n)

	self._hullStart = i0
	local hullSize = 3

	hullNext[i0] = i1
	hullPrev[i2] = i1
	hullNext[i1] = i2
	hullPrev[i0] = i2
	hullNext[i2] = i0
	hullPrev[i1] = i0

	hullTri[i0] = 0
	hullTri[i1] = 1
	hullTri[i2] = 2

	for i = 1, self._hashSize do
		hullHash[i] = -1
	end
	hullHash[Delaunay2d._hashKey(self, i0x, i0y) + 1] = i0
	hullHash[Delaunay2d._hashKey(self, i1x, i1y) + 1] = i1
	hullHash[Delaunay2d._hashKey(self, i2x, i2y) + 1] = i2

	self.trianglesLen = 0
	Delaunay2d._addTriangle(self, i0, i1, i2, -1, -1, -1)

	local xp = 0
	local yp = 0

	for k = 1, #self._ids do
		local i = self._ids[k]
		local x = coordX(coords, i)
		local y = coordY(coords, i)

		if k > 1 and isNearlyEqual(x, xp) and isNearlyEqual(y, yp) then
			continue
		end
		xp, yp = x, y

		if i == i0 or i == i1 or i == i2 then
			continue
		end

		local start = -1
		local key = Delaunay2d._hashKey(self, x, y)
		for j = 0, self._hashSize - 1 do
			start = hullHash[((key + j) % self._hashSize) + 1]
			if start ~= -1 and start ~= hullNext[start] then
				break
			end
		end

		if start == -1 then
			continue
		end

		start = hullPrev[start]
		local e = start

		while true do
			local q = hullNext[e]
			local orient =
				DelaunayUtil.Orient2d(x, y, coordX(coords, e), coordY(coords, e), coordX(coords, q), coordY(coords, q))
			if orient < 0 then
				break
			end

			e = q
			if e == start then
				e = -1
				break
			end
		end

		if e == -1 then
			continue
		end

		local t = Delaunay2d._addTriangle(self, e, i, hullNext[e], -1, -1, hullTri[e])
		hullTri[i] = Delaunay2d._legalize(self, t + 2)
		hullTri[e] = t
		hullSize += 1

		local nEdge = hullNext[e]
		while true do
			local q = hullNext[nEdge]
			local orient = DelaunayUtil.Orient2d(
				x,
				y,
				coordX(coords, nEdge),
				coordY(coords, nEdge),
				coordX(coords, q),
				coordY(coords, q)
			)
			if orient >= 0 then
				break
			end

			t = Delaunay2d._addTriangle(self, nEdge, i, q, hullTri[i], -1, hullTri[nEdge])
			hullTri[i] = Delaunay2d._legalize(self, t + 2)
			hullNext[nEdge] = nEdge
			hullSize -= 1
			nEdge = q
		end

		if e == start then
			while true do
				local q = hullPrev[e]
				local orient = DelaunayUtil.Orient2d(
					x,
					y,
					coordX(coords, q),
					coordY(coords, q),
					coordX(coords, e),
					coordY(coords, e)
				)
				if orient >= 0 then
					break
				end

				t = Delaunay2d._addTriangle(self, q, i, e, -1, hullTri[e], hullTri[q])
				Delaunay2d._legalize(self, t + 2)
				hullTri[q] = t
				hullNext[e] = e
				hullSize -= 1
				e = q
			end
		end

		self._hullStart = e
		hullPrev[i] = e
		hullNext[e] = i
		hullPrev[nEdge] = i
		hullNext[i] = nEdge

		hullHash[Delaunay2d._hashKey(self, x, y) + 1] = i
		hullHash[Delaunay2d._hashKey(self, coordX(coords, e), coordY(coords, e)) + 1] = e
	end

	local hull = table.create(hullSize, 0)
	local e = self._hullStart
	for i = 1, hullSize do
		hull[i] = e
		e = hullNext[e]
	end
	self.hull = hull

	local triangles = table.create(self.trianglesLen, 0)
	local halfedges = table.create(self.trianglesLen, -1)
	for i = 1, self.trianglesLen do
		triangles[i] = self._triangles[i]
		halfedges[i] = self._halfedges[i]
	end
	self.triangles = triangles
	self.halfedges = halfedges
end

function Delaunay2d.GetTriangles(self: Delaunay2dInternal): { number }
	return self.triangles
end

function Delaunay2d.GetHalfedges(self: Delaunay2dInternal): { number }
	return self.halfedges
end

function Delaunay2d.GetHull(self: Delaunay2dInternal): { number }
	return self.hull
end

function Delaunay2d.ForEachTriangle(self: Delaunay2dInternal): () -> (number, number, number)
	local triangles = self.triangles
	local i = 1
	return function(): (number, number, number)
		if i > #triangles then
			return nil :: any, nil :: any, nil :: any
		end

		local a, b, c = triangles[i], triangles[i + 1], triangles[i + 2]
		i += 3
		return a, b, c
	end
end

function Delaunay2d.GetEdges(self: Delaunay2dInternal): { { number } }
	local triangles = self.triangles
	local halfedges = self.halfedges
	local edges: { { number } } = {}
	for e = 0, #triangles - 1 do
		local opposite = halfedges[e + 1]
		if opposite == -1 or e < opposite then
			local a = triangles[e + 1]
			local b = triangles[(e % 3 == 2) and (e - 1) or (e + 2)]
			edges[#edges + 1] = { a, b }
		end
	end
	return edges
end

function Delaunay2d.Triangulate(vertices: { Vector2 }): TriangulationResult
	local tri = Delaunay2d.new(vertices)
	local triInternal = tri :: Delaunay2dInternal
	return {
		Triangles = triInternal:GetTriangles(),
		Halfedges = triInternal:GetHalfedges(),
		Hull = triInternal:GetHull(),
	}
end

function Delaunay2d.TriangulateFrom3d(vertices: { Vector3 }, normal: Vector3?): TriangulationResult
	local projected = projectVertices(vertices, normal)
	return Delaunay2d.Triangulate(projected)
end

return Delaunay2d
