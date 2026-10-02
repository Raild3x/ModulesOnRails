--!strict
-- Repro (Track M2, ticket 37): the step-height rule (MaxStepHeight, ticket 34) makes no riser
-- where the upper slab is tilted down away from the step. A tilted block's end face leans with
-- it, so the bottom of that face overhangs the lower floor; the rule reads the overhang as a cut
-- in the riser's band and leaves the whole edge out.
--   lune run tools/navmesh/bench/riser_lean_repro.luau
-- Expected: risers both ways. Today: 1 riser when the slab rises from the step, 0 when it falls.
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local CFrame, Vector3 = roblox.CFrame, roblox.Vector3
local newInstance = (roblox.Instance :: any).new

local function part(size: any, cf: any): any
	local p = newInstance("Part")
	p.Size, p.CFrame = size, cf
	return p
end

-- A level 10 x 10 floor (top y = 0), and a 1-thick slab from x = 10 to 20 whose top starts 0.5
-- up at the step and climbs by `rise` (negative: falls).
for _, rise in { 1, -1 } do
	local x0, y0, x1, y1 = 10, 0.5, 20, 0.5 + rise
	local len = math.sqrt(100 + rise * rise)
	local nx, ny = -rise / len, 10 / len
	local slab = part(
		Vector3.new(len, 1, 10),
		CFrame.new((x0 + x1) / 2 - nx / 2, (y0 + y1) / 2 - ny / 2, 5) * CFrame.Angles(0, 0, math.atan2(rise, 10))
	)
	local ground = part(Vector3.new(10, 1, 10), CFrame.new(5, -0.5, 5))
	local desc = Adapter.FromParts({ ground, slab }, {}, { MaxStepHeight = 1 }) :: any
	local risers = 0
	for name in desc.Floors do
		risers += if string.find(name, "^Riser") then 1 else 0
	end
	desc.MaxAgentRadius = 1
	local path = NavMesh.FindPath(NavMesh.Build(desc), vector.create(5, 0, 5), vector.create(15, 0.5 + rise / 2, 5))
	print(`slab {if rise > 0 then "rises" else "falls"} from the step: {risers} riser(s), path {path.Status}`)
end
