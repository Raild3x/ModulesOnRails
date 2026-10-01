--!strict
-- Repro (Track M2, ticket 37): the Part adapter loses seams between tilted Parts, or emits
-- zero-length ones that NavMesh.Build rejects. Part data is f32, so a hinge between two rotated
-- Parts is collinear only to about 1e-5 studs; `clipSegment` in NavMeshAdapter wants 1e-12.
--   lune run tools/navmesh/bench/adapter_f32_seams.luau
-- Fixed 2026-10-01 (known-gaps.md). Expected: hinged strip 6 seams and Success; the wedge field
-- builds and paths Success.
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local CFrame, Vector3 = roblox.CFrame, roblox.Vector3
local newInstance = (roblox.Instance :: any).new

local function part(class: string, size: any, cf: any): any
	local p = newInstance(class)
	p.Size, p.CFrame = size, cf
	return p
end

local function report(label: string, walkable: { any }, from: vector, to: vector)
	local desc = Adapter.FromParts(walkable, {}) :: any
	desc.MaxAgentRadius = 1
	local ok, mesh = pcall(NavMesh.Build, desc)
	if not ok then
		print(`{label}: {#desc.Seams} seams, Build error: {mesh}`)
		return
	end
	print(`{label}: {#desc.Seams} seams, path {NavMesh.FindPath(mesh, from, to, { AgentRadius = 0.5 }).Status}`)
end

-- 1. Seven 1-stud slabs whose top faces form a profile along X, hinged edge to edge.
local ys = { 0, 0.9, 0.5, 1.6, 1.2, 0.4, 0.4, 1.1 }
local strip = {}
for i = 1, #ys - 1 do
	local x0, y0, x1, y1 = (i - 1) * 10, ys[i], i * 10, ys[i + 1]
	local dx, dy = x1 - x0, y1 - y0
	local len = math.sqrt(dx * dx + dy * dy)
	local nx, ny = -dy / len, dx / len
	local cf = CFrame.new((x0 + x1) / 2 - nx / 2, (y0 + y1) / 2 - ny / 2, 4) * CFrame.Angles(0, 0, math.atan2(dy, dx))
	table.insert(strip, part("Part", Vector3.new(len, 1, 8), cf))
end
report("hinged strip (7 floors, 6 hinges)", strip, vector.create(1, 0, 4), vector.create(69, 1.1, 4))

-- 2. A 2 x 2 cell heightfield, each triangle two thin WedgeParts (the usual triangle trick).
local function triangle(a: any, b: any, c: any, out: { any })
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local down = if right.Y > 0 then -right else right
	local h = math.abs(ab:Dot(up))
	table.insert(
		out,
		part(
			"WedgePart",
			Vector3.new(0.2, h, math.abs(ab:Dot(back))),
			CFrame.fromMatrix((a + b) / 2 + down * 0.1, right, up, back)
		)
	)
	table.insert(
		out,
		part(
			"WedgePart",
			Vector3.new(0.2, h, math.abs(ac:Dot(back))),
			CFrame.fromMatrix((a + c) / 2 + down * 0.1, -right, up, -back)
		)
	)
end
local heights = { { 0, 0.6, 0.1 }, { 0.4, -0.3, 0.8 }, { 0.2, 0.7, 0 } }
local field = {}
for i = 0, 1 do
	for j = 0, 1 do
		local function P(a: number, b: number): any
			return Vector3.new(a * 10, heights[a + 1][b + 1], b * 10)
		end
		triangle(P(i, j), P(i + 1, j), P(i + 1, j + 1), field)
		triangle(P(i, j), P(i + 1, j + 1), P(i, j + 1), field)
	end
end
report("wedge field (8 triangles)", field, vector.create(1, 0, 1), vector.create(19, 0, 19))
